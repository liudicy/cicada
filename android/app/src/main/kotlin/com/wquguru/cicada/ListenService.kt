package com.wquguru.cicada

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import cicada.Log
import cicada.Strings.L

/// Keeps listening alive with the screen off or another app in front, as a foreground service
/// whose notification is the Android counterpart of the Mac's menu bar panel: what is being heard,
/// for how long, the newest line, and 结束. Its type is mediaProjection (what the phone plays) or
/// microphone (面对面), as Android 14 requires.
class ListenService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val app = cicada
        if (intent?.action == ACTION_STOP) { app.stopListening(); return START_NOT_STICKY }
        if (intent?.action == ACTION_KEEP) { app.keepRecording(); return START_NOT_STICKY }
        val kind = intent?.getStringExtra("kind") ?: run { stopSelf(); return START_NOT_STICKY }
        channel(this)
        // In the foreground with the right type first; only then may the projection be taken.
        val type = when (kind) {
            "playback" -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            "import" -> ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            else -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        try {
            startForeground(ID, notification(this), type)
        } catch (e: Exception) {
            Log.d("service: foreground refused ${e.javaClass.simpleName}")
            app.startProblem = L("没能开始听")
            app.starting = 0
            app.changed()
            stopSelf()
            return START_NOT_STICKY
        }
        if (kind == "import") {
            val uri = intent.data ?: run { stopSelf(); return START_NOT_STICKY }
            app.beginImport(uri)
            return START_NOT_STICKY
        }
        val source = if (kind == "playback") {
            val data: Intent? = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra("data", Intent::class.java) else @Suppress("DEPRECATION") intent.getParcelableExtra("data")
            val code = intent.getIntExtra("code", Activity.RESULT_CANCELED)
            val projection = data?.let { (getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager).getMediaProjection(code, it) }
            if (projection == null) { app.startProblem = L("没能开始听"); app.starting = 0; app.changed(); stopSelf(); return START_NOT_STICKY }
            // The user can end sharing from the status bar: listening ends with it.
            projection.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() { if (app.listen.listening && app.listen.sourceKind == "playback") app.stopListening() }
            }, app.main)
            PlaybackSource(projection, applicationInfo.uid)
        } else MicSource(applicationContext)
        app.began(source, kind)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    companion object {
        const val ID = 1
        const val ACTION_STOP = "com.wquguru.cicada.STOP"
        const val ACTION_KEEP = "com.wquguru.cicada.KEEP"
        private const val CHANNEL = "listening"
        private var lastText: String? = null

        fun channel(context: Context) {
            val nm = context.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(NotificationChannel(CHANNEL, L("正在听"), NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        }

        fun notification(context: Context): Notification {
            val app = context.cicada
            val listen = app.listen
            val session = listen.sessionId?.let { app.store.get(it) }
            val line = listen.sessionId?.let { app.store.lines(it).lastOrNull() }
            // 正在听 over 首页, so back from it stays in the app.
            val open = android.app.TaskStackBuilder.create(context)
                .addNextIntent(Intent(context, MainActivity::class.java))
                .addNextIntent(Intent(context, ListeningActivity::class.java))
                .getPendingIntent(0, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val stop = PendingIntent.getService(context, 1, Intent(context, ListenService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
            val ending = app.ending
            val file = app.importing
            val title = when {
                file != null -> L("知了 · 正在转写") + " " + (session?.sourceFile ?: "")
                ending != null -> app.endingTitle(ending)
                listen.sourceKind == "mic" -> L("知了 · 面对面")
                else -> L("知了 · 正在听手机里的声音")
            }
            val text = if (file != null) "${cicada.Languages.clock(file.done)} / ${cicada.Languages.clock(file.total)}"
                else if (ending != null) app.endingDetail(ending) else listen.problem ?: line?.let { it.dst ?: it.src } ?: L("等有人说话…")
            val b = Notification.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setUsesChronometer(session != null)
                .setWhen(session?.startedAt?.toEpochMilli() ?: System.currentTimeMillis())
                .setContentIntent(open)
            // About to end by itself: the same two choices as the 正在听 strip.
            if (ending != null) {
                val keep = PendingIntent.getService(context, 2, Intent(context, ListenService::class.java).setAction(ACTION_KEEP), PendingIntent.FLAG_IMMUTABLE)
                b.addAction(Notification.Action.Builder(null, L("继续记录"), keep).build())
                b.addAction(Notification.Action.Builder(null, L("现在结束"), stop).build())
            } else b.addAction(Notification.Action.Builder(null, L("结束"), stop).build())
            return b.setCategory(Notification.CATEGORY_SERVICE).build()
        }

        /// The notification follows the newest line (only when its text changes).
        fun refresh(context: Context) {
            val app = context.cicada
            if (!app.listen.listening || (app.listen.sourceKind == "file" && app.importing == null)) { lastText = null; return }
            val text = app.importing?.let { "${it.done.toInt()}" } + app.listen.sessionId?.let { app.store.lines(it).lastOrNull()?.let { l -> l.dst ?: l.src } } + "|" + app.listen.problem +
                "|" + app.ending?.let { app.endingLeft(it) }
            if (text == lastText) return
            lastText = text
            if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED && Build.VERSION.SDK_INT >= 33) return
            context.getSystemService(NotificationManager::class.java).notify(ID, notification(context))
        }
    }
}

/// A see-through activity that gets what listening needs before ListenService starts: the
/// microphone permission (Android asks for it even to capture other apps), the notification
/// permission, and for playback the system's screen-capture consent, which is single-use.
class ProjectionActivity : Activity() {
    private lateinit var kind: String

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        kind = intent.getStringExtra("kind") ?: "playback"
        // Recreated (rotation) while a permission or consent dialog is up: that dialog's result still comes.
        if (savedInstanceState != null) return
        val needed = mutableListOf<String>()
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.POST_NOTIFICATIONS)
        if (needed.isNotEmpty()) requestPermissions(needed.toTypedArray(), 1) else next()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            cicada.startProblem = L("需要麦克风权限才能听")
            cicada.starting = 0
            cicada.changed()
            finish(); return
        }
        next()
    }

    private fun next() {
        if (kind == "playback") {
            val mpm = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            // The whole device, not "one app": what is heard is every app's sound, and the
            // one-app picker would only confuse (Android 14+).
            val consent = if (Build.VERSION.SDK_INT >= 34)
                mpm.createScreenCaptureIntent(android.media.projection.MediaProjectionConfig.createConfigForDefaultDisplay())
            else mpm.createScreenCaptureIntent()
            @Suppress("DEPRECATION")
            startActivityForResult(consent, 2)
        } else {
            startForegroundService(Intent(this, ListenService::class.java).putExtra("kind", kind))
            finish()
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (resultCode == RESULT_OK && data != null) {
            startForegroundService(Intent(this, ListenService::class.java).putExtra("kind", kind).putExtra("code", resultCode).putExtra("data", data))
        } else {
            Log.d("projection: declined")
            cicada.starting = 0
        }
        finish()
    }
}
