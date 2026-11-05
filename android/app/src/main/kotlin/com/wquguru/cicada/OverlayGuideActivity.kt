package com.wquguru.cicada

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import cicada.Log
import cicada.Strings.L

/// 显示在其他应用上层: asked for, and when Android holds it back, unlocked step by step.
///
/// Android 15+ holds this switch back from apps installed from a file (downloaded by a browser or
/// chat app, or opened in a file manager): it shows 已停用 and refuses once with 系统已拒绝…, and
/// only after that refusal does app info's ⋮ menu offer 允许受限制的设置. Checked in the emulator:
/// Android 15 and 16 hold it back; 14 (where 13's restriction covers accessibility and
/// notification access only) and 10 don't. Store and USB installs aren't held back. Android
/// doesn't tell an app whether it is held back, so the guide judges by the version, how it was
/// installed and the switch still being off when the person comes back.
class OverlayGuideActivity : Activity() {
    private enum class Stage { Ask, Retry, Unlock, LastStep, Xiaomi, Done }

    private lateinit var ui: Ui
    private var tried = false        // the overlay switch's page has been opened
    private var unlockOpened = false // app info (for ⋮ › 允许受限制的设置) has been opened
    private var shown: Stage? = null
    private val watch get() = intent.getBooleanExtra("watch", false)
    private val direct get() = intent.getBooleanExtra("direct", false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ui = Ui(this)
        tried = savedInstanceState?.getBoolean("tried") ?: false
        unlockOpened = savedInstanceState?.getBoolean("unlockOpened") ?: false
        // From a row that already says what it's for (onboarding, settings): straight to the switch.
        if (savedInstanceState == null && direct && !cicada.canOverlay) openSwitch()
    }

    override fun onSaveInstanceState(out: Bundle) {
        super.onSaveInstanceState(out)
        out.putBoolean("tried", tried); out.putBoolean("unlockOpened", unlockOpened)
    }

    override fun onResume() {
        super.onResume()
        val stage = when {
            cicada.canOverlay -> if (direct && !watch) { finish(); return } else Stage.Done
            !tried -> if (direct) return else Stage.Ask
            xiaomi -> Stage.Xiaomi
            restrictedLikely(this) -> if (unlockOpened) Stage.LastStep else Stage.Unlock
            else -> Stage.Retry
        }
        if (stage == shown) return
        shown = stage
        Log.d("overlay guide: $stage (sdk=${Build.VERSION.SDK_INT} source=${installSource(this)} maker=${Build.MANUFACTURER})")
        show(stage)
    }

    private fun openSwitch() {
        tried = true
        unlockOpened = false
        start(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
    }

    private fun openAppInfo() {
        unlockOpened = true
        start(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
    }

    /// Xiaomi's own permission page (其他权限), else app info.
    private fun openXiaomi() {
        tried = true
        val miui = Intent("miui.intent.action.APP_PERM_EDITOR").putExtra("extra_pkgname", packageName)
        if (!start(miui)) start(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
    }

    private fun start(i: Intent): Boolean = try { startActivity(i); true } catch (_: Exception) { false }

    private fun done() {
        val app = cicada
        if (watch && app.listen.listening) {
            app.overlayThisMeeting = true
            app.overlayClosed = false
            moveTaskToBack(true)
        }
        finish()
    }

    // MARK: Screens

    private fun show(stage: Stage) {
        val body = ui.stack(0)
        val bottom: View
        when (stage) {
            Stage.Ask -> {
                body.addView(preview(), ui.lp(top = 8, height = ui.dp(168)))
                body.addView(ui.title(L("让字幕浮在视频上"), 26f), ui.lp(top = 24))
                body.addView(ui.text(L("需要打开“显示在其他应用上层”。只用来显示字幕卡片。"), 15f, Palette.secondary), ui.lp(top = 8))
                bottom = ui.stack(4, ui.button(L("去打开"), "primary") { openSwitch() },
                                     ui.textButton(L("先不用，在知了里看")) { finish() }).apply {
                    setPadding(ui.dp(16), ui.dp(14), ui.dp(16), ui.dp(20)); background = ui.rounded(Palette.card, 0)
                }
            }
            Stage.Retry -> {
                body.addView(ui.title(L("还没打开"), 26f), ui.lp(top = 4))
                body.addView(ui.text(L("在列表里找到“知了”，把开关打开。"), 15f, Palette.secondary), ui.lp(top = 8))
                bottom = ui.bottomBar(ui.button(L("在知了里看"), "quiet") { finish() }, ui.button(L("再去打开"), "primary") { openSwitch() })
            }
            Stage.Unlock, Stage.LastStep -> {
                val last = stage == Stage.LastStep
                body.addView(ui.title(L("系统先拦住了这个开关"), 26f), ui.lp(top = 4))
                body.addView(ui.text(L("从浏览器或聊天 app 下载安装的应用，Android 要你先解锁一次。"), 15f, Palette.secondary), ui.lp(top = 8))
                body.addView(steps(
                    step(1, L("点一次那个开关，系统提示已拒绝"), done = true),
                    step(2, L("打开应用信息，点右上角 ⋮ ›“允许受限制的设置”，再验证锁屏密码"), done = last, extra = if (last) null else menuSketch()),
                    step(3, L("回到“显示在其他应用上层”，打开知了"), current = last),
                ), ui.lp(top = 20))
                if (!last) body.addView(ui.helper(L("看不到 ⋮？先去点一次那个开关，被拒绝后菜单才会出现。")), ui.lp(top = 14))
                bottom = ui.bottomBar(ui.button(L("在知了里看"), "quiet") { finish() },
                    if (last) ui.button(L("打开开关"), "primary") { openSwitch() } else ui.button(L("打开应用信息"), "primary") { openAppInfo() })
            }
            Stage.Xiaomi -> {
                body.addView(ui.badge(L("小米 HyperOS"), Palette.secondary, Palette.card), ui.lp(top = 4, width = -2))
                body.addView(ui.title(L("还差两个开关"), 26f), ui.lp(top = 10))
                body.addView(ui.text(L("小米把悬浮窗放在“其他权限”里，并且要允许后台弹出。"), 15f, Palette.secondary), ui.lp(top = 8))
                body.addView(steps(
                    step(1, L("点下面的“打开权限设置”"), current = true),
                    step(2, L("“其他权限”里，把“显示悬浮窗”和“后台弹出界面”设为允许")),
                    step(3, L("提示“受限制的设置”时，先在应用详情右上角 ⋮ 解锁")),
                ), ui.lp(top = 20))
                body.addView(ui.helper(L("不同系统版本叫法略有不同，找带“悬浮窗”的那一项。")), ui.lp(top = 14))
                bottom = ui.bottomBar(ui.button(L("在知了里看"), "quiet") { finish() }, ui.button(L("打开权限设置"), "primary") { openXiaomi() })
            }
            Stage.Done -> {
                body.gravity = Gravity.CENTER_HORIZONTAL
                body.addView(FrameLayout(this).apply {
                    background = ui.rounded(Palette.accentPale, 36)
                    addView(ui.icon(R.drawable.i_check, 34, Palette.accent), FrameLayout.LayoutParams(ui.dp(34), ui.dp(34), Gravity.CENTER))
                }, LinearLayout.LayoutParams(ui.dp(72), ui.dp(72)).apply { topMargin = ui.dp(48) })
                body.addView(ui.title(L("好了，字幕会浮在视频上"), 24f).apply { gravity = Gravity.CENTER }, ui.lp(top = 20))
                body.addView(ui.text(L("回到视频就能看到字幕卡片，拖到角落可以收起。"), 15f, Palette.secondary).apply { gravity = Gravity.CENTER }, ui.lp(top = 8))
                val back = watch && cicada.listen.listening
                bottom = ui.bottomBar(ui.button(if (back) L("回到视频") else L("完成"), "primary") { done() })
            }
        }
        body.setPadding(ui.dp(24), 0, ui.dp(24), ui.dp(24))
        setContentView(ui.screen(this, null, back = true, ground = Palette.ground, bottom = bottom, body = body))
    }

    /// A video with the subtitle card over it: what the switch is for.
    private fun preview() = FrameLayout(this).apply {
        background = ui.rounded(Palette.ink, 20)
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        addView(ui.icon(R.drawable.i_play, 40, Palette.outline), FrameLayout.LayoutParams(ui.dp(40), ui.dp(40), Gravity.CENTER_HORIZONTAL).apply { topMargin = ui.dp(34) })
        addView(ui.stack(2, ui.text("Let's move the launch to next Thursday.", 11f, Palette.secondary, lines = 1),
                            ui.text(L("我们把发布改到下周四吧。"), 15f, Palette.ink, bold = true, lines = 1)).apply {
            background = ui.rounded(Palette.card, 14); setPadding(ui.dp(12), ui.dp(10), ui.dp(12), ui.dp(10))
        }, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM).apply { setMargins(ui.dp(16), 0, ui.dp(16), ui.dp(16)) })
    }

    private fun steps(vararg rows: View) = ui.stack(0).apply {
        background = ui.rounded(Palette.card, 20)
        setPadding(ui.dp(18), ui.dp(4), ui.dp(18), ui.dp(4))
        rows.forEachIndexed { i, r ->
            if (i > 0) addView(ui.divider(), LinearLayout.LayoutParams(-1, 1))
            addView(r)
        }
    }

    /// One numbered step: a ✓ once done, filled while it's the one to do now.
    private fun step(n: Int, text: String, done: Boolean = false, current: Boolean = false, extra: View? = null) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        setPadding(0, ui.dp(14), 0, ui.dp(14))
        val mark = FrameLayout(context).apply {
            background = ui.rounded(if (done) Palette.accentPale else if (current || extra != null) Palette.ink else Palette.ground, 14)
            if (done) addView(ui.icon(R.drawable.i_check, 16, Palette.link), FrameLayout.LayoutParams(ui.dp(16), ui.dp(16), Gravity.CENTER))
            else addView(ui.text("$n", 14f, if (current || extra != null) android.graphics.Color.WHITE else Palette.ink, bold = true).apply { gravity = Gravity.CENTER },
                         FrameLayout.LayoutParams(-1, -1))
        }
        addView(mark, LinearLayout.LayoutParams(ui.dp(28), ui.dp(28)))
        val col = ui.stack(10, ui.text(text, 16f, if (done) Palette.secondary else Palette.ink))
        if (extra != null) col.addView(extra)
        addView(col, ui.weight().apply { leftMargin = ui.dp(14); topMargin = ui.dp(2) })
        contentDescription = (if (done) L("已完成") + "：" else "") + text
    }

    /// App info's top bar with ⋮ ringed and the item it opens.
    private fun menuSketch() = ui.stack(8).apply {
        background = ui.rounded(Palette.ground, 14)
        setPadding(ui.dp(12), ui.dp(10), ui.dp(12), ui.dp(10))
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(ui.text(L("应用信息"), 12f, Palette.secondary), ui.weight())
            addView(ui.text("⋮", 16f, Palette.ink, bold = true).apply { gravity = Gravity.CENTER; background = ui.rounded(Palette.card, 14, Palette.accent, 2) },
                    LinearLayout.LayoutParams(ui.dp(28), ui.dp(28)))
        })
        addView(ui.text(L("允许受限制的设置"), 13f, Palette.link, bold = true).apply {
            background = ui.rounded(Palette.card, 10); setPadding(ui.dp(12), ui.dp(8), ui.dp(12), ui.dp(8))
        }, LinearLayout.LayoutParams(-2, -2).apply { gravity = Gravity.END })
    }

    companion object {
        fun open(context: Context, watch: Boolean = false, direct: Boolean = false) {
            context.startActivity(Intent(context, OverlayGuideActivity::class.java).putExtra("watch", watch).putExtra("direct", direct)
                .apply { if (context !is Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) })
        }

        private val xiaomi get() = Build.MANUFACTURER.lowercase() in setOf("xiaomi", "redmi", "poco")

        /// How this copy was installed (Android 13+): 3 a local file, 4 a downloaded file, 2 a store, 0 USB / unknown.
        fun installSource(context: Context): Int = if (Build.VERSION.SDK_INT < 33) -1 else try {
            context.packageManager.getInstallSourceInfo(context.packageName).packageSource
        } catch (_: Exception) { -1 }

        /// Android 15+ holds the switch back from a copy installed from a file.
        fun restrictedLikely(context: Context) = Build.VERSION.SDK_INT >= 35 &&
            installSource(context).let { it == PackageInstaller.PACKAGE_SOURCE_LOCAL_FILE || it == PackageInstaller.PACKAGE_SOURCE_DOWNLOADED_FILE }
    }
}
