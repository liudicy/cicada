package com.wquguru.cicada

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import cicada.Json
import cicada.Strings
import cicada.Log
import cicada.Session
import cicada.Wav
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/// Debug commands for dev builds over `adb shell am broadcast` (scripts/cicadactl.sh): the
/// Android counterpart of the Mac's tools/lsctl and the Windows pipe. One command per broadcast,
/// one JSON line back as the broadcast's result (never meeting text or the key).
///   state | start [playback|mic] | stop | feed <wav in files/> | sample | view notes|subtitles
///   capture on|off | overlay show|hide | show main|live|records|settings|onboarding|record [id] | overlay collapse|expand | key reload
///   hear|say <wav in files/> (面对面: the other side / me holding 我说) | tts <lang> <text>
///   import <session.json in files/> | importfile <audio or video in files/> | face | onboarded on|off | target <code> | ui <lang> | clip <text>
class DebugReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!BuildConfig.DEBUG) return
        val app = context.cicada
        val line = intent.getStringExtra("cmd") ?: "state"
        val pending = goAsync()
        // UI work on the main thread; the reply waits for it, then for state to settle.
        app.background.execute {
            val done = CountDownLatch(1)
            var reply: Map<String, Any?> = emptyMap()
            app.main.post { reply = try { run(app, line) } catch (e: Exception) { mapOf("error" to "${e.javaClass.simpleName}: ${e.message}") }; done.countDown() }
            done.await(5, TimeUnit.SECONDS)
            if (reply.isEmpty()) {
                val again = CountDownLatch(1)
                Thread.sleep(300)
                app.main.post { reply = state(app); again.countDown() }
                again.await(5, TimeUnit.SECONDS)
            }
            pending.resultCode = 0
            pending.resultData = Json.write(reply, pretty = false)
            pending.finish()
        }
    }

    /// Empty: "reply with the state once the command has had a moment".
    private fun run(app: CicadaApp, line: String): Map<String, Any?> {
        val parts = line.trim().split(Regex("\\s+"), 2)
        val arg = parts.getOrElse(1) { "" }
        if (parts[0] != "state") Log.d("debug: ${parts[0]}")
        fun open(cls: Class<*>, extra: String? = null) =
            app.startActivity(Intent(app, cls).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).apply { extra?.let { putExtra("id", it) } })
        when (parts[0]) {
            "state" -> return state(app)
            "start" -> app.startListening(app, arg.ifEmpty { app.settings.source })
            "stop" -> app.stopListening()
            "feed" -> app.listenToFile(File(app.filesDir, arg), play = false)
            "sample" -> app.listenToFile(null, play = true)
            // 导入录音或视频 without the file picker: any audio or video in files/.
            "importfile" -> app.importFile(app, android.net.Uri.fromFile(File(app.filesDir, arg)))
            "face" -> app.startActivity(Intent(app, FaceActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            "view" -> app.setView(if (arg == "subtitles") "subtitles" else "notes")
            "capture" -> { app.settings.showInCapture = arg == "on"; app.saveSettings(); app.overlay.rebuild() }
            "overlay" -> if (arg == "collapse") { app.overlay.collapsed = true; app.overlay.rebuild() } else if (arg == "expand") { app.overlay.collapsed = false; app.overlay.rebuild() } else if (arg == "hide") { app.overlay.forced = false; app.overlay.hide() } else { app.overlay.forced = true; app.overlay.show() }
            // 面对面 without a voice: `hear` plays a WAV as the other side, `say` as me holding 我说.
            "hear" -> app.listen.inject(Wav.read(File(app.filesDir, arg).inputStream()))
            "say" -> { app.holdToSay(); app.listen.inject(Wav.read(File(app.filesDir, arg).inputStream())); app.releaseToSay() }
            // 会议自己结束 in seconds: `endtimes 20 10` (silence, countdown); `endtimes` alone resets.
            "endtimes" -> { val v = arg.split(Regex("\\s+")).mapNotNull { it.toDoubleOrNull() }; app.endTimesOverride = if (v.size == 2) v[0] to v[1] else null }
            "silence" -> { app.settings.silenceEnd = arg.ifEmpty { "prompt" }; app.saveSettings() }
            "keep" -> app.keepRecording()
            "tts" -> {
                val (lang, text) = arg.split(Regex("\\s+"), 2).let { it[0] to it.getOrElse(1) { "Hello." } }
                app.background.execute { Log.d("debug: tts $lang -> ${app.voice.speak(text, lang, {}, {})}") }
                return mapOf("tts" to lang)
            }
            "target" -> { app.settings.target = arg.ifEmpty { "system" }; app.saveSettings() }
            "ui" -> { app.settings.uiLanguage = arg.ifEmpty { "system" }; app.saveSettings(); app.loadStrings(); app.overlay.rebuild() }
            // Puts text on the clipboard (the shell can't), so 粘贴 can be tested.
            "clip" -> app.getSystemService(android.content.ClipboardManager::class.java).setPrimaryClip(android.content.ClipData.newPlainText("test", arg))
            "onboarded" -> { app.settings.onboarded = arg != "off"; app.saveSettings() }
            "key" -> { app.key.reload(); app.ling.keyChanged(); app.background.execute { app.ling.check() } }
            // 检查更新 against a test feed: the dev build checks only once one is set.
            "updatefeed" -> { app.updates.setFeed(if (arg.isEmpty() || arg.contains("://")) arg else File(app.filesDir, arg).path); app.updates.checkIfDue(0) }
            "update" -> when (arg) {
                "check" -> app.updates.checkNow()
                "download" -> app.updates.download()
                "job" -> app.background.execute { app.updates.checkInBackground() }
                "notify" -> app.updates.available?.let { app.updates.notifyAbout(it) }
            }
            "import" -> {
                val s = Session.read(File(app.filesDir, arg).readText()) ?: return mapOf("error" to "unreadable")
                app.store.import(s)
            }
            "show" -> when (arg.substringBefore(' ')) {
                "settings" -> open(SettingsActivity::class.java)
                "onboarding" -> open(OnboardingActivity::class.java)
                "record" -> open(RecordActivity::class.java, arg.substringAfter(' ', "").ifEmpty { app.store.all().firstOrNull { it.id != app.listen.sessionId || !app.listen.listening }?.id })
                "records" -> open(RecordsActivity::class.java)
                "live" -> app.openLive()
                else -> open(MainActivity::class.java)
            }
            else -> return mapOf("error" to "unknown command ${parts[0]}")
        }
        return emptyMap()
    }

    companion object {
        fun state(app: CicadaApp): Map<String, Any?> {
            val listen = app.listen
            val id = listen.sessionId
            return mapOf(
                "listening" to listen.listening,
                "source" to listen.sourceKind,
                "session" to id,
                "lines" to (id?.let { app.store.lines(it).size } ?: 0),
                "translated" to (id?.let { app.store.lines(it).count { l -> l.dst != null } } ?: 0),
                "pending" to listen.pending,
                "ending" to app.ending?.let { mapOf("reason" to it.reason.toString(), "left" to app.endingLeft(it)) },
                "autoEnded" to app.autoEnded,
                "say" to mapOf("can" to listen.canSay, "holding" to listen.holding, "saying" to listen.saying, "muted" to listen.muted, "speaking" to app.voice.speaking, "their" to listen.theirLanguage, "problem" to listen.sayProblem),
                "spoken" to listen.spoken,
                "target" to listen.target,
                "heardSeconds" to Math.round(listen.heardSeconds * 10) / 10.0,
                "peak" to Math.round(listen.peak * 10000) / 10000.0,
                "problem" to (listen.problem ?: app.startProblem),
                "notes" to app.notes.status.name,
                "topics" to app.notes.notes.topics.size,
                "key" to app.ling.keyState.name,
                "view" to app.settings.view,
                "showInCapture" to app.settings.showInCapture,
                "overlay" to app.overlay.describe(),
                "canOverlay" to app.canOverlay,
                "sessions" to app.store.all().size,
                "ui" to Strings.language,
                "update" to mapOf("enabled" to app.updates.enabled, "current" to app.updates.checker.current, "available" to app.updates.available?.version,
                                  "apk" to app.updates.available?.apk, "lastChecked" to app.updates.checker.lastChecked, "notified" to app.settings.updateNotified,
                                  "manual" to app.updates.manual),
            )
        }
    }
}
