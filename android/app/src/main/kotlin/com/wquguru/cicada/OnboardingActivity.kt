package com.wquguru.cicada

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import cicada.KeyState
import cicada.MeetingNotes
import cicada.Providers
import cicada.Strings
import cicada.Strings.L
import cicada.Strings.LF
import cicada.keepsSavedKey

/// First run, three screens, one job each, the main button pinned at the bottom: Ling key → what
/// Cicada can hear and the permissions for it → try the sample meeting.
class OnboardingActivity : Activity() {
    private lateinit var ui: Ui
    private lateinit var host: FrameLayout
    private var step = 0
    private var unobserve: (() -> Unit)? = null
    private var shown: String? = null
    private var progressFill: View? = null
    private var progressClock: android.widget.TextView? = null
    // The sample's progress and clock move on their own; the rest re-renders when lines arrive.
    private val tick = object : Runnable {
        override fun run() {
            val l = cicada.listen
            val playing = l.listening && l.sourceKind == "file"
            progressFill?.let { fill ->
                val bar = fill.parent as View
                (fill.layoutParams as FrameLayout.LayoutParams).width = (bar.width * if (playing) (l.heardSeconds / 9.0).coerceIn(0.0, 1.0) else 0.0).toInt()
                fill.requestLayout()
            }
            progressClock?.text = if (playing) "0:%02d".format(l.heardSeconds.toInt().coerceAtMost(9)) else "0:09"
            cicada.main.postDelayed(this, 250)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ui = Ui(this)
        host = FrameLayout(this)
        setContentView(host)
        step = savedInstanceState?.getInt("step") ?: if (cicada.ling.hasKey && cicada.ling.keyState != KeyState.Invalid) 1 else 0
        render()
    }

    override fun onResume() { super.onResume(); unobserve = cicada.observe { if (step == 2) render(); checkShown?.invoke() }; shown = null; render(); cicada.main.post(tick) }

    /// The key step's (or its sheet's) check, redrawn when the AI client changes: the same step
    /// list as the settings, and on to the next step once it passes.
    private var checkShown: (() -> Unit)? = null
    private var checkKey: String? = null

    /// Fills `into` with the steps of a check this page started; true once it passed.
    private fun showCheck(into: LinearLayout): Boolean {
        val ling = cicada.ling
        val c = ling.aiCheck
        val key = c.summary + Strings.language
        if (key == checkKey) return c.passed
        checkKey = key
        into.removeAllViews()
        if (ling.hasKey && AiCheckViews.showSteps(c) && !c.passed)
            into.addView(ui.group(listOf(AiCheckViews.steps(this, ui, recheck = true) { cicada.key.remove(); cicada.aiChanged(check = false) })))
        return c.passed
    }
    override fun onPause() { super.onPause(); unobserve?.invoke(); unobserve = null; cicada.main.removeCallbacks(tick) }

    // Back goes to the previous step. Android 13+ delivers back through OnBackInvokedCallback
    // (Android 16 no longer calls onBackPressed for apps that target it), registered only while
    // there is a step to go back to, so the system's back animation still works on the first.
    private val stepBack = android.window.OnBackInvokedCallback { step--; shown = null; render() }
    private var stepBackOn = false

    private fun syncBack() {
        if (Build.VERSION.SDK_INT < 33) return
        val want = step > 0
        if (want == stepBackOn) return
        stepBackOn = want
        if (want) onBackInvokedDispatcher.registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT, stepBack)
        else onBackInvokedDispatcher.unregisterOnBackInvokedCallback(stepBack)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() { if (step > 0) { step--; shown = null; render() } else @Suppress("DEPRECATION") super.onBackPressed() }

    override fun onSaveInstanceState(out: Bundle) { super.onSaveInstanceState(out); out.putInt("step", step) }

    private fun next() {
        step++
        if (step > 2) {
            cicada.settings.onboarded = true; cicada.saveSettings()
            // Opened on its own (no home screen under it): go home rather than out of the app.
            if (isTaskRoot) startActivity(Intent(this, MainActivity::class.java))
            finish(); return
        }
        shown = null
        render()
    }

    private fun render() {
        val key = "$step|" + (if (step == 2) NotesViews.liveKey(cicada) + cicada.store.all().size else "") + (if (step == 1) perms() else "")
        if (key == shown) return
        shown = key
        syncBack()
        host.removeAllViews()
        host.addView(when (step) { 0 -> keyStep(); 1 -> hearStep(); else -> sampleStep() })
        // A view added after the first layout gets the system bars' insets only when asked.
        host.requestApplyInsets()
    }

    private fun perms() = listOf(micGranted, notifyGranted, cicada.canOverlay).joinToString()
    private val micGranted get() = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    private val notifyGranted get() = Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    /// The step's frame: progress (and a back arrow after the first), the content, the main button.
    private fun frame(content: View, button: View): View {
        val progress = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            contentDescription = "${step + 1} / 3"
            (0..2).forEach { i -> addView(View(context).apply { background = ui.rounded(if (i <= step) Palette.accent else Palette.outline, 2) },
                                          LinearLayout.LayoutParams(0, ui.dp(4), 1f).apply { if (i > 0) leftMargin = ui.dp(6) }) }
        }
        val topBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = ui.dp(56)
            setPadding(ui.dp(if (step > 0) 4 else 24), 0, ui.dp(24), 0)
            if (step > 0) addView(ui.iconButton(R.drawable.i_back, L("返回")) { step--; shown = null; render() }, LinearLayout.LayoutParams(ui.dp(48), ui.dp(48)).apply { rightMargin = ui.dp(4) })
            addView(progress, ui.weight())
        }
        content.setPadding(ui.dp(24), ui.dp(16), ui.dp(24), ui.dp(24))
        val bottom = FrameLayout(this).apply { setPadding(ui.dp(24), ui.dp(12), ui.dp(24), ui.dp(20)); addView(button) }
        val root = ui.screen(this, null, back = false, ground = Palette.ground, body = content, bottom = bottom)
        window.navigationBarColor = Palette.ground
        bottom.setBackgroundColor(Palette.ground)
        // The screen's own bar is replaced by the progress bar. The bar is the first child of the
        // column inside the root (the root's other child is the floating bottom), not of the root.
        val column = root.getChildAt(0) as LinearLayout
        column.removeViewAt(0)
        column.addView(topBar, 0)
        return root
    }

    private fun intro(title: String, lead: String) = ui.stack(8, ui.title(title), ui.text(lead, 16f, Palette.body).apply { leading(1.3f) })

    private fun keyStep(): View {
        val app = cicada
        val status = ui.text("", 13f, Palette.secondary)
        lateinit var submit: () -> Unit
        val box = ui.keyField { submit() }
        val field = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = ui.dp(56)
            background = ui.rounded(Palette.card, 16, Palette.outline, 2)
            setPadding(ui.dp(16), 0, ui.dp(6), 0)
            addView(box, ui.weight())
            addView(ui.button(L("粘贴"), "quiet", R.drawable.i_clipboard, height = 44) { SettingsActivity.paste(box) })
        }
        fun showStatus(text: String, problem: Boolean) {
            status.text = text
            status.setTextColor(if (problem) Palette.link else Palette.secondary)
            status.setCompoundDrawablesRelative(if (problem) null else ui.drawable(R.drawable.i_lock, Palette.secondary).apply { setBounds(0, 0, ui.dp(14), ui.dp(14)) }, null, null, null)
            status.compoundDrawablePadding = ui.dp(6)
            field.background = ui.rounded(Palette.card, 16, if (problem) Palette.link else Palette.outline, 2)
            if (problem) status.announceForAccessibility(text)
        }
        showStatus(LF("加密存在这台手机上，只发给 %@", app.ling.serviceName), false)
        // When the keyboard opens the page shrinks: once it has (the IME inset arrives), scroll to
        // the end so the field and the line under it sit above the pinned button.
        var imeShown = false
        box.viewTreeObserver.addOnGlobalLayoutListener {
            val ime = box.rootWindowInsets?.isVisible(android.view.WindowInsets.Type.ime()) == true
            if (ime && !imeShown && box.hasFocus()) {
                var p = box.parent
                while (p != null && p !is android.widget.ScrollView) p = p.parent
                (p as? android.widget.ScrollView)?.let { sv -> sv.post { sv.smoothScrollTo(0, sv.getChildAt(0).height) } }
            }
            imeShown = ime
        }
        // Another service's key pasted here: what it is, and 改用 it with one tap.
        val other = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val steps = ui.stack(0)
        var tried = false
        checkKey = null
        checkShown = {
            if (step == 0 && tried && app.ling.hasKey) {
                if (showCheck(steps)) { tried = false; checkShown = null; next() }
                else if (!app.ling.aiCheck.running) showStatus(LF("加密存在这台手机上，只发给 %@", app.ling.serviceName), false)
            }
        }
        submit = submit@{
            val text = box.text.toString().trim()
            other.removeAllViews()
            // Onboarding never blocks: a key that was checked and failed still goes on (the steps say why).
            if (tried && !app.ling.aiCheck.running && (text.isEmpty() || text == app.ling.currentKey())) { checkShown = null; next(); return@submit }
            // The guide opened again with a working key saved: an empty field keeps it.
            if (!tried && keepsSavedKey(text, app.ling.currentKey(), app.ling.keyState)) { checkShown = null; next(); return@submit }
            if (AiServiceActivity.keyHint(ui, text, "ling", status, other) { tried = true; checkKey = null; status.text = L("正在检查…") }) {
                field.background = ui.rounded(Palette.card, 16, Palette.link, 2)
                return@submit
            }
            if (!text.startsWith("sk-")) { showStatus(L("要粘贴 sk- 开头的 Ling key"), true); return@submit }
            // Back on this page after choosing another service: a Ling key means Ling again.
            app.setAiProvider("ling", check = false)
            app.key.save(text)
            app.ling.keyChanged()
            tried = true
            checkKey = null
            status.text = L("正在检查…"); status.setTextColor(Palette.secondary)
            app.background.execute { app.ling.check() }
        }
        fun stepRow(n: Int, text: String, action: View? = null) = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = ui.dp(56)
            setPadding(ui.dp(16), ui.dp(8), ui.dp(if (action != null) 8 else 16), ui.dp(8))
            addView(ui.text("$n", 14f, Palette.ink, bold = true).apply { gravity = Gravity.CENTER; background = ui.rounded(Palette.ground, 14) }, LinearLayout.LayoutParams(ui.dp(28), ui.dp(28)))
            addView(ui.text(text, 15f, Palette.ink), ui.weight().apply { leftMargin = ui.dp(14) })
            if (action != null) addView(action)
        }
        val open = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = ui.dp(48)
            setPadding(ui.dp(12), 0, ui.dp(12), 0)
            addView(ui.text(L("打开"), 15f, Palette.link, bold = true))
            addView(ui.icon(R.drawable.i_external, 16, Palette.link), LinearLayout.LayoutParams(ui.dp(16), ui.dp(16)).apply { leftMargin = ui.dp(4) })
            contentDescription = L("打开 Ling 开放平台")
            ui.tappable(this, 24) { try { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://chat.ant-ling.com/platform/api"))) } catch (_: Exception) {} }
        }
        val content = ui.stack(20,
            ui.logo(64),
            intro(L("接上 Ling"), L("识别、翻译和纪要都靠它，大约 1 分钟")),
            ui.group(listOf(stepRow(1, L("打开 Ling 开放平台"), open), stepRow(2, L("点“创建令牌”，复制 sk- 开头的 Ling key")), stepRow(3, L("回到这里粘贴")))),
            ui.stack(8, ui.text(L("Ling key"), 13f, Palette.body, bold = true).apply { setPadding(ui.dp(4), 0, 0, 0); labelFor = View.generateViewId().also { box.id = it } }, field, status.apply { setPadding(ui.dp(4), 0, 0, 0) }, other, steps),
            // A way out for people who can't use Ling: another service, in a sheet, saying what it lacks.
            ui.textButton(L("用不了 Ling？"), Palette.link) { otherService() }.apply {
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            })
        return frame(content, ui.button(L("继续"), "primary") { submit() })
    }

    /// 用其他服务 (OnboardingKey.swift › otherEntry): OpenRouter or ZenMux, their key, and what they
    /// lack. The service switches only once its key checks out; a custom address is set up in
    /// 设置 › AI 服务.
    private fun otherService() {
        val app = cicada
        var chosen = app.settings.aiProvider.takeIf { it == "openrouter" || it == "zenmux" } ?: "zenmux"
        lateinit var dialog: android.app.Dialog
        val sheet = ui.stack(14)
        fun render() {
            sheet.removeAllViews()
            val p = Providers.named(chosen)
            val status = ui.text(LF("加密存在这台手机上，只发给 %@", p.name), 13f, Palette.secondary)
            lateinit var check: (String) -> Unit
            lateinit var box: android.widget.EditText
            box = ui.keyField { check(box.text.toString().trim()) }.apply { hint = LF("粘贴 %@ 的 key", p.name) }
            fun problem(text: String) { status.text = text; status.setTextColor(Palette.link); status.announceForAccessibility(text) }
            val other = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            val steps = ui.stack(0)
            // After a check that failed: the steps say why, and onboarding still goes on.
            val goOn = ui.textButton(L("继续"), Palette.link) { checkShown = null; dialog.dismiss(); next() }.apply { visibility = View.GONE }
            fun watch() {
                checkKey = null
                checkShown = {
                    if (showCheck(steps)) { checkShown = null; dialog.dismiss(); next() }
                    else {
                        val c = app.ling.aiCheck
                        if (!c.running) status.text = LF("加密存在这台手机上，只发给 %@", app.ling.serviceName)
                        goOn.visibility = if (!c.running && c.failure != null) View.VISIBLE else View.GONE
                    }
                }
            }
            check = check@{ text ->
                other.removeAllViews()
                if (AiServiceActivity.keyHint(ui, text, p.id, status, other) { status.text = L("正在检查…"); watch() }) return@check
                if (!text.startsWith("sk-")) { problem(LF("剪贴板里没有 sk- 开头的 key，请先去 %@ 复制。", p.name)); return@check }
                // The service and key stay as chosen even if the check fails: the steps say why.
                app.setAiProvider(p.id, check = false)
                app.key.save(text)
                app.aiChanged(check = false)
                status.text = L("正在检查…"); status.setTextColor(Palette.secondary)
                watch()
                app.background.execute { app.ling.check() }
            }
            val field = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                minimumHeight = ui.dp(56)
                background = ui.rounded(Palette.ground, 16)
                setPadding(ui.dp(16), 0, ui.dp(6), 0)
                addView(box, ui.weight())
            }
            val open = ui.listRow(LF("打开 %@", p.name), L("注册或登录后点“创建令牌”"), trailing = ui.icon(R.drawable.i_external, 18, Palette.link), chevron = false) {
                try { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(p.site))) } catch (_: Exception) {}
            }.apply { background = ui.rounded(Palette.ground, 16) }
            val gap = if (Strings.language == "zh-Hans") "" else " "
            val lacks = ui.text(L("少了：") + gap + L("你自己的声音") + gap + L("（只有 Ling 支持）"), 13f, Palette.secondary).apply {
                background = ui.rounded(Palette.ground, 12)
                setPadding(ui.dp(12), ui.dp(8), ui.dp(12), ui.dp(8))
            }
            sheet.addView(ui.helper(L("听、纪要和翻译都能用，模型已经选好。")).apply { gravity = Gravity.CENTER })
            sheet.addView(ui.segmented(listOf("openrouter" to "OpenRouter", "zenmux" to "ZenMux"), chosen) { chosen = it; render() })
            sheet.addView(open)
            sheet.addView(field)
            sheet.addView(status.apply { setPadding(ui.dp(4), 0, ui.dp(4), 0) })
            sheet.addView(other)
            sheet.addView(steps.apply { background = ui.rounded(Palette.ground, 16) })
            sheet.addView(goOn.apply { layoutParams = LinearLayout.LayoutParams(-2, -2).apply { gravity = Gravity.CENTER_HORIZONTAL } })
            sheet.addView(ui.button(L("粘贴并检查"), "primary", R.drawable.i_clipboard) {
                SettingsActivity.paste(box)
                check(box.text.toString().trim())
            })
            sheet.addView(lacks)
            sheet.addView(ui.textButton(L("‹ 还是用 Ling"), Palette.link) { dialog.dismiss() }.apply {
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { gravity = Gravity.CENTER_HORIZONTAL }
            })
        }
        render()
        dialog = ui.sheet(this, L("用其他服务"), android.widget.ScrollView(this).apply { addView(sheet) })
        dialog.window?.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        dialog.show()
    }

    private fun hearStep(): View {
        fun source(iconRes: Int, title: String, helper: String) = ui.stack(8, ui.icon(iconRes, 26, Palette.ink), ui.text(title, 15f, Palette.ink, bold = true), ui.helper(helper)).apply {
            background = ui.rounded(Palette.card, 20)
            setPadding(ui.dp(16), ui.dp(16), ui.dp(16), ui.dp(16))
        }
        val sources = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(source(R.drawable.i_speaker, L("手机里的声音"), L("视频、直播、网课")), LinearLayout.LayoutParams(0, -1, 1f))
            addView(source(R.drawable.i_mic, L("面对面"), L("线下开会；有人在线上就把会议 app 开外放")), LinearLayout.LayoutParams(0, -1, 1f).apply { leftMargin = ui.dp(10) })
        }
        val limit = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(ui.dp(4), 0, ui.dp(4), 0)
            addView(ui.icon(R.drawable.i_info, 18, Palette.secondary), LinearLayout.LayoutParams(ui.dp(18), ui.dp(18)).apply { topMargin = ui.dp(1) })
            addView(ui.helper(L("微信通话、腾讯会议、Zoom 的声音系统不让录，开外放用“面对面”听")), ui.weight().apply { leftMargin = ui.dp(10) })
        }
        fun perm(title: String, why: String, granted: Boolean, action: String, onAsk: () -> Unit): View {
            val trailing: View = if (granted) ui.row(4, ui.icon(R.drawable.i_check, 16, Palette.body), ui.text(L("已允许"), 13f, Palette.body, bold = true))
                                 else ui.button(action, "tonal", height = 40) { onAsk() }
            return ui.listRow(title, why, trailing = trailing, chevron = false)
        }
        val list = ui.group(listOf(
            perm(L("麦克风"), L("系统要求两种来源都开麦克风"), micGranted, L("允许")) {
                requestPermissions(listOfNotNull(Manifest.permission.RECORD_AUDIO, if (Build.VERSION.SDK_INT >= 33) Manifest.permission.POST_NOTIFICATIONS else null).toTypedArray(), 1)
            },
            perm(L("通知"), L("锁屏也能看到正在听，随时结束"), notifyGranted, L("允许")) {
                if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2)
            },
            perm(L("显示在其他应用上层"), L("在视频上直接看字幕（在列表里找“知了”开启）"), cicada.canOverlay, L("去设置")) {
                OverlayGuideActivity.open(this, direct = true)
            }))
        val content = ui.stack(16, intro(L("知了能听什么"), L("两种来源，每次开始听时都能选")), sources, limit, ui.sectionLabel(L("需要的权限")), list)
        return frame(content, ui.button(L("继续"), "primary") { next() })
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) { shown = null; render() }

    private fun sampleStep(): View {
        val app = cicada
        val listen = app.listen
        val playing = listen.listening && listen.sourceKind == "file"
        val heard = listen.sessionId?.let { app.store.get(it) }
        val player = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = ui.rounded(Palette.card, 20)
            setPadding(ui.dp(14), ui.dp(14), ui.dp(16), ui.dp(14))
            val button = android.widget.FrameLayout(context).apply {
                background = ui.rounded(Palette.ink, 24)
                addView(ui.icon(if (playing) R.drawable.i_stop else R.drawable.i_play, 20, android.graphics.Color.WHITE), FrameLayout.LayoutParams(ui.dp(20), ui.dp(20), Gravity.CENTER))
                contentDescription = if (playing) L("停止") else L("播放示例")
                ui.tappable(this, 24, ui.rounded(Palette.ink, 24), dark = true) { if (playing) app.stopListening() else app.listenToFile(null, play = true) }
            }
            addView(button, LinearLayout.LayoutParams(ui.dp(48), ui.dp(48)))
            val bar = FrameLayout(context).apply {
                background = ui.rounded(Palette.selected, 2)
                addView(View(context).apply { background = ui.rounded(Palette.accent, 2) }, FrameLayout.LayoutParams(0, -1).apply { width = 0 })
            }
            val texts = ui.stack(10, ui.text(L("示例会议 · 英语"), 15f, Palette.ink, medium = true), bar.apply { layoutParams = LinearLayout.LayoutParams(-1, ui.dp(4)) })
            addView(texts, ui.weight().apply { leftMargin = ui.dp(14) })
            progressFill = bar.getChildAt(0)
            progressClock = ui.text("0:09", 13f, Palette.secondary)
            addView(progressClock, LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(12) })
        }
        val content = ui.stack(16, intro(L("试一下"), L("放一段 9 秒的示例会议，看看字幕和纪要怎么出来")), player)
        val lines = heard?.lines.orEmpty()
        val line = lines.lastOrNull()
        if (line != null) {
            val card = NotesViews.liveCard(ui, app, line, 20f, dots = playing)
            card.addView(ui.text(L("字幕"), 13f, Palette.secondary, bold = true), 0)
            (card.getChildAt(1).layoutParams as? LinearLayout.LayoutParams)?.topMargin = ui.dp(10)
            // The lines before the newest stay above it: the sample's two come back half a second
            // apart, and showing only the newest made the first one flash by.
            lines.dropLast(1).takeLast(2).forEachIndexed { i, l ->
                val row = ui.stack(2, ui.text(NotesViews.said(l), 13f, Palette.secondary))
                if (!l.dst.isNullOrEmpty() && l.dst != l.shown) row.addView(ui.text(l.dst!!, 15f, Palette.ink))
                card.addView(row, 1 + i, ui.lp(top = 10))
            }
            content.addView(card, ui.lp(top = 12))
            val notes = heard?.notes ?: if (app.notes.shownId == heard?.id) app.notes.notes else null
            val notesCard = ui.stack(8, ui.text(L("纪要"), 13f, Palette.secondary, bold = true),
                NotesViews.notesBody(ui, notes ?: MeetingNotes(), app.notes.status, true, compact = true)).apply {
                background = ui.rounded(Palette.card, 20)
                setPadding(ui.dp(18), ui.dp(16), ui.dp(18), ui.dp(16))
            }
            content.addView(notesCard, ui.lp(top = 12))
        } else if (playing) {
            // Ming answers a stretch once it ends (the sample's first, ~7 s in): say it's coming.
            content.addView(ui.stack(10, ui.text(L("字幕"), 13f, Palette.secondary, bold = true),
                LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    listOf(1f, 0.6f, 0.3f).forEach { a -> addView(ui.dot(Palette.accent, 6).apply { alpha = a }, LinearLayout.LayoutParams(ui.dp(6), ui.dp(6)).apply { rightMargin = ui.dp(5) }) }
                    addView(ui.text(L("正在听下一句…"), 15f, Palette.secondary), LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(4) })
                }).apply {
                background = ui.rounded(Palette.card, 20)
                setPadding(ui.dp(18), ui.dp(16), ui.dp(18), ui.dp(16))
            }, ui.lp(top = 12))
        } else {
            content.addView(LinearLayout(this).apply {
                layoutParams = ui.lp(top = 12)
                orientation = LinearLayout.HORIZONTAL
                setPadding(ui.dp(4), 0, ui.dp(4), 0)
                addView(ui.icon(R.drawable.i_eye_off, 18, Palette.secondary), LinearLayout.LayoutParams(ui.dp(18), ui.dp(18)).apply { topMargin = ui.dp(1) })
                addView(ui.helper(L("悬浮窗浮在别的 app 上，不挡打字，截图和录屏里也看不到")), ui.weight().apply { leftMargin = ui.dp(10) })
            })
        }
        return frame(content, ui.button(L("开始使用"), "primary") { next() })
    }
}
