package com.wquguru.cicada

import android.app.Application
import android.content.Context
import android.content.Intent
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import cicada.AIKey
import cicada.AppSettings
import cicada.AudioSource
import cicada.LingClient
import cicada.ListenEngine
import cicada.Log
import cicada.MeetingEndWatch
import cicada.NotesEngine
import cicada.Paths
import cicada.PcmAudioSource
import cicada.SessionStore
import cicada.SpeakerLabels
import cicada.Strings
import cicada.Translator
import cicada.Wav
import java.io.File
import java.util.Locale
import java.util.concurrent.Executors

/// The process: wires the engines together (AppModel on the Mac, Controller on Windows) and tells
/// the screens when something changed. Engine events arrive on worker threads; `observe`
/// callbacks run on the main thread, coalesced to one per frame.
class CicadaApp : Application() {
    lateinit var settings: AppSettings
    lateinit var key: AIKey
    lateinit var ling: LingClient
    lateinit var store: SessionStore
    lateinit var notes: NotesEngine
    lateinit var translator: Translator
    lateinit var listen: ListenEngine
    lateinit var overlay: Overlay
    lateinit var voice: Voice
    lateinit var updates: AppUpdates
    val main = Handler(Looper.getMainLooper())
    val background = Executors.newCachedThreadPool { r -> Thread(r, "App").apply { isDaemon = true } }
    private val observers = LinkedHashSet<() -> Unit>()
    private var refreshQueued = false
    private var tileListening = false
    private var samplePlayer: MediaPlayer? = null
    /// Why the last listening couldn't start or ended early, shown on the main screen.
    @Volatile var startProblem: String? = null
    /// Cicada's own screens in front: the floating window is for other apps, so it waits.
    private var resumed = 0
    /// One of Cicada's screens is in front.
    val foreground get() = resumed > 0
    /// Android silenced our recording: a phone call, or another app holding the microphone.
    @Volatile var micSilenced = false
    /// The user closed the floating window (×) for this meeting.
    var overlayClosed = false
    /// 在视频上看 asked for it in this meeting, whatever 悬浮窗 is set to.
    var overlayThisMeeting = false
    /// 保存会议录音: the meeting's recorder while one runs.
    private var recorder: Recorder? = null
    /// 导入录音或视频: the file being transcribed, while it is.
    @Volatile var importing: FileSource? = null; private set

    override fun onCreate() {
        super.onCreate()
        shared = this
        Paths.root = filesDir
        Paths.log = File(cacheDir, if (BuildConfig.DEBUG) "cicada-dev-debug.log" else "cicada-debug.log")
        if (BuildConfig.DEBUG) Log.sink = { android.util.Log.d("Cicada", it) }
        settings = AppSettings.load()
        SpeakerLabels.voices = settings.speakerVoices
        // The phone's whole language list, not the app's own locale: "follow system" falls back to
        // the next one when they speak mine (the Mac's Locale.preferredLanguages).
        AppSettings.systemLanguages = {
            val list = android.content.res.Resources.getSystem().configuration.locales
            (0 until list.size()).map { list[it].toLanguageTag() }
        }
        loadStrings()
        key = AIKey(KeystoreProtector)
        ling = LingClient(key).apply { model = settings.model }
        store = SessionStore(loadNow = false)
        background.execute { val t = System.currentTimeMillis(); store.load(); Log.d("store: loaded ${store.all().size} in ${System.currentTimeMillis() - t} ms") }
        notes = NotesEngine(ling, store)
        translator = Translator(ling)
        listen = ListenEngine(ling, translator, store, notes, settings)
        listen.encoder = { pcm ->
            val t = System.currentTimeMillis()
            AacEncoder.encode(pcm)?.also { Log.d("listen: ${pcm.size * 2 / 1024} KB PCM → ${it.bytes.size / 1024} KB ${it.type} in ${System.currentTimeMillis() - t} ms") }
        }
        overlay = Overlay(this)
        voice = Voice(this)
        listen.onSaid = ::speakAloud
        listen.onWords = { main.post { endWatch?.heard(now()); setEnding(endWatch?.pending) } }
        listen.onChange(::changed)
        notes.onChange(::changed)
        store.onChange { changed() }
        ling.onChange(::changed)
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            // Meetings are private: the recent-apps preview shows a blank card, not the transcript
            // (Android 13+). Screenshots of the app itself still work.
            override fun onActivityPreCreated(a: android.app.Activity, b: android.os.Bundle?) {
                if (Build.VERSION.SDK_INT >= 33 && a !is ProjectionActivity) a.setRecentsScreenshotEnabled(false)
            }
            override fun onActivityResumed(a: android.app.Activity) { resumed++; updateOverlay() }
            // Moving between Cicada's own screens pauses one before resuming the next: wait a beat.
            override fun onActivityPaused(a: android.app.Activity) { resumed--; main.postDelayed(::updateOverlay, 400) }
            override fun onActivityCreated(a: android.app.Activity, b: android.os.Bundle?) {}
            override fun onActivityStarted(a: android.app.Activity) {}
            override fun onActivityStopped(a: android.app.Activity) {}
            override fun onActivitySaveInstanceState(a: android.app.Activity, b: android.os.Bundle) {}
            override fun onActivityDestroyed(a: android.app.Activity) {}
        })
        Log.d("app: launch ${if (BuildConfig.DEBUG) "dev" else "release"} sdk=${Build.VERSION.SDK_INT}")
        if (ling.hasKey) background.execute { ling.check() }
        updates = AppUpdates(this)
        updates.start()
    }

    fun loadStrings() {
        val ui = if (settings.uiLanguage == "system") Locale.getDefault().toLanguageTag() else settings.uiLanguage
        Strings.load(ui) { rel -> try { assets.open("Resources/$rel").use { it.readBytes().toString(Charsets.UTF_8) } } catch (_: Exception) { null } }
    }

    // MARK: Changes

    fun observe(observer: () -> Unit): () -> Unit {
        observers.add(observer)
        return { observers.remove(observer) }
    }

    fun changed() {
        main.post {
            if (refreshQueued) return@post
            refreshQueued = true
            main.postDelayed({
                refreshQueued = false
                updateOverlay()
                overlay.refresh()
                if (listen.listening != tileListening) { tileListening = listen.listening; ListenTile.refresh(this) }
                ListenService.refresh(this)
                observers.toList().forEach { it() }
            }, 16)
        }
    }

    // MARK: Listening

    val canOverlay get() = Settings.canDrawOverlays(this)

    /// Playback capture needs the projection consent first: ProjectionActivity asks, then hands
    /// the result to ListenService. The microphone and files start straight away.
    /// Between 开始听 and the service starting (permissions, the consent dialog): further taps wait.
    @Volatile var starting = 0L

    fun startListening(context: Context, kind: String) {
        startIntent(context, kind)?.let { context.startActivity(it) }
    }

    /// What starting takes: the permissions and consent screen, or onboarding without a key. Null
    /// while already listening or starting (a second tap). The Quick Settings tile opens it itself.
    fun startIntent(context: Context, kind: String): Intent? {
        if (listen.listening) return null
        if (System.currentTimeMillis() - starting < 60_000) return null
        startProblem = null
        if (!ling.hasKey) return Intent(context, OnboardingActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        starting = System.currentTimeMillis()
        return Intent(context, ProjectionActivity::class.java).putExtra("kind", kind).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    /// Called by ListenService once it is in the foreground, with the source it made.
    fun began(source: AudioSource, kind: String) {
        starting = 0
        micSilenced = false
        (source as? RecordSource)?.onSilenced = { silenced -> if (silenced != micSilenced) { micSilenced = silenced; changed() } }
        source.onEnded = { reason ->
            if (reason != null) {
                Log.d("listen: source ended $reason")
                startProblem = Strings.L("声音来源停了")
                stopListening()
            }
        }
        overlayClosed = false
        overlayThisMeeting = false
        overlay.collapsed = false
        listen.start(source, kind)
        startRecording()
        watchEnd()
        if (kind == "mic") background.execute { voice.warm() }
        openLive()
    }

    // MARK: 我说 (面对面)

    fun holdToSay() {
        // Pressing again while the phone still speaks: stop it, it's my turn.
        if (voice.speaking) { voice.stop(); listen.muted = false }
        listen.hold()
    }

    fun releaseToSay() = listen.release()

    /// My words in their language, out of the phone's speaker. The mic is muted for the segmenter
    /// meanwhile (and a beat after, for the room's echo) so the phone doesn't hear itself as them.
    private fun speakAloud(text: String, lang: String) {
        listen.muted = true
        changed()
        val r = voice.speak(text, lang, onStart = { changed() }, onEnd = {
            main.postDelayed({ if (!voice.speaking) { listen.muted = false; changed() } }, 400)
        })
        // A TTS engine that drops the utterance never calls back: don't stay deaf to the other side.
        if (r == Voice.Result.Spoken) main.postDelayed({ if (listen.muted && !voice.speaking) { listen.muted = false; changed() } }, 3_000L + text.length * 150L)
        if (r != Voice.Result.Spoken) {
            listen.muted = false
            listen.sayFailed(if (r == Voice.Result.NoVoice) Strings.L("手机不会读这个语言") else Strings.L("没能读出来"))
        }
    }

    // MARK: Meeting end (the Mac's MeetingEndWatch: on Android only "nobody spoke", since no app
    // may see another one's microphone; so no hang-up signal and no 会议应用挂断后结束)

    /// The meeting ends at `deadline` unless someone keeps it going: the 正在听 strip, the floating
    /// window and the notification show it.
    @Volatile var ending: MeetingEndWatch.Pending? = null; private set
    /// The last meeting ended by itself: 首页 says 会议已自动结束 instead of nothing.
    @Volatile var autoEnded = false; private set
    private var endWatch: MeetingEndWatch? = null
    /// Debug (`endtimes <silence> <countdown>`): seconds instead of minutes, to test it.
    var endTimesOverride: Pair<Double, Double>? = null

    private fun now() = System.currentTimeMillis() / 1000.0

    private val endConfig: MeetingEndWatch.Config get() = MeetingEndWatch.Config(
        followApps = false,
        silence = MeetingEndWatch.Silence.of(settings.silenceEnd),
        silenceAfter = endTimesOverride?.first ?: (settings.silenceMinutes * 60),
        countdown = endTimesOverride?.second ?: 60.0,
    )

    private val endTick = object : Runnable {
        override fun run() {
            val w = endWatch ?: return
            if (!listen.listening) return
            w.config = endConfig
            val said = listen.sessionId?.let { store.lines(it).isNotEmpty() } ?: false
            val reason = w.tick(now(), emptyMap(), said)
            setEnding(w.pending)
            if (reason != null) { autoEnd(reason, w); return }
            // Every second while counting down (the seconds left show), else every 2 s as on the Mac.
            main.postDelayed(this, if (w.pending != null) 1000 else 2000)
        }
    }

    private fun watchEnd() {
        autoEnded = false
        endWatch = MeetingEndWatch(endConfig, now())
        main.removeCallbacks(endTick)
        main.postDelayed(endTick, 2000)
    }

    private fun setEnding(p: MeetingEndWatch.Pending?) {
        if (p == ending) { if (p != null) changed(); return }
        if (p != null) Log.d("meeting end: pending ${p.reason}, ends in ${(p.deadline - now()).toInt()} s")
        else if (ending != null) Log.d("meeting end: pending cleared")
        ending = p
        changed()
    }

    fun endingTitle(p: MeetingEndWatch.Pending): String = when (val r = p.reason) {
        is MeetingEndWatch.Reason.AppLeft -> Strings.LF("%@ 已挂断", r.name)
        else -> Strings.LF("已经 %lld 分钟没人说话", maxOf(1, Math.round(endConfig.silenceAfter / 60).toInt()))
    }

    fun endingLeft(p: MeetingEndWatch.Pending) = maxOf(0, Math.round(p.deadline - now()).toInt())

    fun endingDetail(p: MeetingEndWatch.Pending) = Strings.LF("%lld 秒后结束会议并整理纪要", endingLeft(p))

    /// "继续记录" on the ending prompt.
    fun keepRecording() {
        endWatch?.keepGoing(now())
        setEnding(null)
        Log.d("meeting end: kept going")
    }

    /// Ends where the meeting really ended: a little after the last words. Never before a line
    /// that was kept (lastSpeech is when the newest line arrived).
    private fun autoEnd(reason: MeetingEndWatch.Reason, w: MeetingEndWatch) {
        if (reason == MeetingEndWatch.Reason.NobodySpoke) {
            // Nothing to keep or summarise: back to 开始听, not 会议已自动结束.
            Log.d("meeting end: nobody spoke for ${w.config.silenceAfter.toInt()} s, stopped")
            stopListening()
            return
        }
        val at = java.time.Instant.ofEpochMilli(((w.lastSpeech + 5) * 1000).toLong())
        Log.d("meeting end: ended by itself ($reason), end time ${(now() - w.lastSpeech - 5).toInt()} s ago")
        stopListening(endedAt = at) { autoEnded = true; changed() }
    }

    /// The 正在听 screen, brought to the front.
    fun openLive() {
        startActivity(Intent(this, ListeningActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
    }

    fun stopListening(endedAt: java.time.Instant? = null, then: (() -> Unit)? = null) {
        voice.stop()
        autoEnded = false
        endWatch = null
        setEnding(null)
        val rec = recorder; recorder = null; listen.tap = null
        val recId = listen.sessionId
        val imported = importing; importing = null
        background.execute {
            listen.stop(endedAt)
            if (imported != null && recId != null) store.update(recId) { it.importing = null }
            rec?.finish { ok -> if (ok && recId != null && store.get(recId) != null) store.update(recId) { it.hasAudio = true } }
            main.post {
                starting = 0
                micSilenced = false
                stopService(Intent(this, ListenService::class.java))
                samplePlayer?.release(); samplePlayer = null
                changed()
                then?.invoke()
            }
        }
    }

    /// A WAV (16 kHz or any PCM16) heard as if it were playing: the sample meeting and `feed`.
    fun listenToFile(file: File?, play: Boolean, showLive: Boolean = !play) {
        if (listen.listening) return
        if (!ling.hasKey) { startProblem = Strings.L("需要 Ling key 才能听"); changed(); return }
        val source = if (file != null) PcmAudioSource(file) else PcmAudioSource({ assets.open("sample.wav").use { Wav.read(it) } })
        source.onEnded = { reason ->
            // A file that finished: give the last segment's reply a moment, then end the meeting.
            main.postDelayed({ if (listen.listening && listen.sourceKind == "file") stopListening() }, if (reason == null) 3000 else 0)
        }
        overlayClosed = false
        overlayThisMeeting = false
        overlay.collapsed = false
        listen.start(source, "file")
        startRecording()
        watchEnd()
        if (showLive) openLive()
        if (play) {
            try {
                val fd = assets.openFd("sample.wav")
                samplePlayer = MediaPlayer().apply {
                    setDataSource(fd.fileDescriptor, fd.startOffset, fd.length)
                    prepare(); start()
                }
            } catch (e: Exception) { Log.d("sample: play failed ${e.javaClass.simpleName}") }
        }
        changed()
    }

    /// The floating window shows while listening with another app in front (unless turned off
    /// or closed), and goes when listening ends: inside Cicada the screens show the same.
    fun updateOverlay() {
        val want = listen.listening && (settings.overlay || overlayThisMeeting) && canOverlay && resumed == 0 && !overlayClosed
        if (want) overlay.show() else if (!overlay.forced) overlay.hide()
    }

    fun setView(view: String) {
        settings.view = view; settings.save()
        overlay.rebuild()
        changed()
    }

    fun saveSettings() { settings.save(); ling.model = settings.model; SpeakerLabels.voices = settings.speakerVoices; changed() }

    /// 保存会议录音: what is heard goes to system.m4a as it comes (the Mac keeps it the same way).
    private fun startRecording() {
        val id = listen.sessionId ?: return
        if (!settings.recordAudio) return
        val rec = Recorder(store.audioFile(id))
        recorder = rec
        listen.tap = { rec.write(it) }
    }

    // MARK: 导入录音或视频 (the Mac's FileImport)

    /// From 首页's 导入 or another app's 分享到知了: the file is transcribed as a meeting (dated
    /// now, named after the file) in the foreground service, so it goes on in the background.
    fun importFile(context: Context, uri: android.net.Uri) {
        if (listen.listening) { startProblem = Strings.L("正在听的时候不能导入，先结束这场会议"); changed(); return }
        if (!ling.hasKey) { context.startActivity(Intent(context, OnboardingActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); return }
        startProblem = null
        try { context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) } catch (_: Exception) {}
        val intent = Intent(context, ListenService::class.java).putExtra("kind", "import").setData(uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startForegroundService(intent)
    }

    /// Called by ListenService once it is in the foreground.
    fun beginImport(uri: android.net.Uri) {
        if (listen.listening) return
        val name = FileSource.name(this, uri)
        val source = FileSource(this, uri)
        source.onEnded = { reason ->
            if (reason != null) main.post { startProblem = Strings.L("这个文件读不出声音"); changed() }
            // A file that finished: give the last segments' replies a moment, then end the meeting.
            // The record lasts as long as the file, not as long as transcribing it took.
            main.postDelayed({
                if (!listen.listening || importing !== source) return@postDelayed
                val start = listen.sessionId?.let { store.get(it) }?.startedAt
                stopListening(endedAt = start?.plusMillis((source.done * 1000).toLong()))
            }, if (reason == null) 3000 else 0)
        }
        overlayClosed = true
        importing = source
        listen.start(source, "file")
        listen.sessionId?.let { id -> store.update(id) { it.sourceFile = name; it.importing = true } }
        startRecording()
        Log.d("import: started")
        changed()
        // Progress for the screens and the notification, a few times a second.
        val tick = object : Runnable {
            override fun run() { if (importing === source) { changed(); main.postDelayed(this, 500) } }
        }
        main.postDelayed(tick, 500)
    }

    /// The system language, or this app's own in Settings › App languages (Android 13+), changed:
    /// the screens are recreated, and they read the new table.
    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        if (settings.uiLanguage == "system") { loadStrings(); changed() }
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        store.flush()
    }

    companion object {
        lateinit var shared: CicadaApp
    }
}

val Context.cicada: CicadaApp get() = applicationContext as CicadaApp
