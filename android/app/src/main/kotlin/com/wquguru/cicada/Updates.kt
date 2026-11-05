package com.wquguru.cicada

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import cicada.Log
import cicada.Strings.L
import cicada.Strings.LF
import cicada.UpdateChecker

/// 检查更新 (the Windows App's Updates part): finds a newer APK on GitHub Releases and says so on
/// 首页 (below the start card, not while listening), in 设置 › 其他, and once per version in a
/// notification. 更新 hands the APK link to the browser; the system installer does the rest.
class AppUpdates(private val app: CicadaApp) {
    val checker = UpdateChecker(app.packageManager.getPackageInfo(app.packageName, 0).versionName ?: "0", app.settings.updateLastChecked)
    /// Release builds check; the dev build only once `updatefeed` points it somewhere.
    @Volatile var enabled = !BuildConfig.DEBUG; private set
    /// 检查更新 in 设置: null, or the answer to the last manual check for a few seconds.
    @Volatile var manual: String? = null; private set
    private val clearManual = Runnable { manual = null; app.changed() }

    val available get() = if (enabled) checker.available else null

    fun start() {
        checker.onChange {
            app.main.post {
                app.settings.updateLastChecked = checker.lastChecked
                app.settings.save()
                if (checker.available == null) cancelNotification()
                app.changed()
            }
        }
        // Updated since the last notification: it is about this version or an older one.
        app.settings.updateNotified?.let { if (!UpdateChecker.isNewer(it, checker.current)) cancelNotification() }
        if (!enabled) return
        schedule()
        checkIfDue(UpdateChecker.STALE)
    }

    fun checkIfDue(age: Long) { if (enabled) app.background.execute { checker.checkIfDue(age) } }

    /// The debug command `updatefeed`: another release JSON, checked now.
    fun setFeed(feed: String) {
        checker.feed = feed.ifEmpty { UpdateChecker.FEED }
        enabled = true
        schedule()
        Log.d("update: feed set")
    }

    /// 检查更新: says 正在检查… / 已是最新版本 / 连不上 GitHub for a few seconds.
    fun checkNow() {
        if (manual == L("正在检查…")) return
        enabled = true
        app.main.removeCallbacks(clearManual)
        manual = L("正在检查…"); app.changed()
        app.background.execute {
            val reached = checker.check()
            app.main.post {
                manual = if (checker.available != null) null else if (reached) L("已是最新版本") else L("连不上 GitHub，请稍后再试")
                app.changed()
                app.main.postDelayed(clearManual, 4000)
            }
        }
    }

    /// 更新: the browser downloads the APK (or shows the release page when there is none).
    fun download() { available?.let { open(it.apk ?: it.page); Log.d("update: download ${it.version}") } }

    fun openNotes() { available?.let { open(it.page) } }

    private fun open(url: String) {
        try { app.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        catch (e: Exception) { Log.d("update: open failed ${e.javaClass.simpleName}") }
    }

    // MARK: In the background

    /// About once a day while the phone has a network; the job survives a restart.
    private fun schedule() {
        try {
            val js = app.getSystemService(JobScheduler::class.java)
            if (js.getPendingJob(JOB) != null) return
            val r = js.schedule(JobInfo.Builder(JOB, ComponentName(app, UpdateJob::class.java))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setPeriodic(24 * 3600_000L, 6 * 3600_000L)
                .setPersisted(true)
                .build())
            Log.d("update: job scheduled ${r == JobScheduler.RESULT_SUCCESS}")
        } catch (e: Exception) { Log.d("update: job not scheduled ${e.javaClass.simpleName}") }
    }

    /// The job's check: a new version gets one notification, unless Cicada is in front (首页 says
    /// it) or a meeting is going on (the next run tells, the version not yet marked as told).
    fun checkInBackground() {
        if (!enabled) return
        checker.check()
        val u = checker.available ?: return
        app.main.post {
            if (app.settings.updateNotified == u.version) return@post
            if (app.foreground || app.listen.listening) { Log.d("update: ${u.version} not notified now"); return@post }
            notifyAbout(u)
        }
    }

    fun notifyAbout(u: UpdateChecker.Update) {
        val nm = app.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, L("检查更新"), NotificationManager.IMPORTANCE_DEFAULT))
        fun view(code: Int, url: String) = PendingIntent.getActivity(app, code, Intent(Intent.ACTION_VIEW, Uri.parse(url)), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = Notification.Builder(app, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(LF("有新版本 %@", u.version))
            .setContentText(L("点按更新"))
            .setContentIntent(view(10, u.apk ?: u.page))
            .addAction(Notification.Action.Builder(null, L("更新说明"), view(11, u.page)).build())
            .setAutoCancel(true)
            .build()
        nm.notify(NOTIFICATION, n)
        app.settings.updateNotified = u.version
        app.settings.save()
        Log.d("update: notified ${u.version}")
    }

    private fun cancelNotification() = app.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION)

    companion object {
        const val JOB = 7
        const val NOTIFICATION = 2
        private const val CHANNEL = "updates"
    }
}

class UpdateJob : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        val app = cicada
        app.background.execute {
            app.updates.checkInBackground()
            jobFinished(params, false)
        }
        return true
    }

    override fun onStopJob(params: JobParameters) = true
}
