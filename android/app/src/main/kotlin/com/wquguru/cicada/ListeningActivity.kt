package com.wquguru.cicada

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import cicada.Languages
import cicada.Strings.L
import cicada.Strings.LF

/// 正在听: the meeting as it happens. Subtitles stream in (newest large, at the bottom) or the
/// live notes; 在视频上看 goes back to the other app, where the floating window takes over; 结束
/// ends it and opens the record.
class ListeningActivity : Activity() {
    private lateinit var ui: Ui
    private lateinit var tabsHost: FrameLayout
    private lateinit var content: LinearLayout
    private lateinit var scroll: ScrollView
    private lateinit var badgeText: TextView
    private lateinit var sourceText: TextView
    private lateinit var bottomHost: FrameLayout
    private var bottomKind: String? = "-"
    private var sayButton: LinearLayout? = null
    private var sayLabel: TextView? = null
    private var sayHelper: TextView? = null
    private var tab = 0 // 0 实时纪要, 1 字幕
    private var shown: String? = null
    private var unobserve: (() -> Unit)? = null
    private val tick = object : Runnable {
        // The clock, and states that come without an event (20 s of silence): render() is keyed.
        override fun run() { badgeText.text = NotesViews.status(cicada); render(); NotesViews.tickEnding(content, cicada); cicada.main.postDelayed(this, 1000) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ui = Ui(this)
        // 实时纪要 first and by default, as on the Mac; 面对面 opens on 字幕, where each line is read
        // as it comes (and 我说's replies show).
        tab = savedInstanceState?.getInt("tab") ?: if (cicada.listen.sourceKind == "mic") 1 else 0
        badgeText = ui.text(NotesViews.status(cicada), 14f, Palette.ink, bold = true, lines = 1).apply { fontFeatureSettings = "tnum" }
        // 正在听 · 12:48 in a white pill, the live dot in the accent (the design's B).
        val badge = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = android.view.Gravity.CENTER_VERTICAL
            background = ui.rounded(Palette.card, 22)
            minimumHeight = ui.dp(44)
            setPadding(ui.dp(14), 0, ui.dp(16), 0)
            ui.lift(this, 1)
            addView(ui.dot(Palette.accent, 8))
            addView(badgeText, LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(8) })
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_NONE
        }
        sourceText = ui.helper("").apply { gravity = android.view.Gravity.CENTER }
        tabsHost = FrameLayout(this)
        content = ui.stack(12).apply { setPadding(ui.dp(16), ui.dp(12), ui.dp(16), ui.dp(16)) }
        scroll = ScrollView(this).apply { isVerticalScrollBarEnabled = false; addView(content); isFillViewport = true }
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(tabsHost, LinearLayout.LayoutParams(-1, -2).apply { leftMargin = ui.dp(16); rightMargin = ui.dp(16); topMargin = ui.dp(8) })
            addView(sourceText, LinearLayout.LayoutParams(-1, -2).apply { topMargin = ui.dp(10) })
            addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f))
        }
        bottomHost = FrameLayout(this)
        buildBottom()
        actionHost = FrameLayout(this)
        setContentView(ui.screen(this, null, back = true, ground = Palette.ground, center = badge, bottom = bottomHost, scroll = false, body = body,
                                 actions = listOf(actionHost)))
        buildAction()
    }

    private lateinit var actionHost: FrameLayout
    private var actionKind: String? = null

    /// Top right: 在视频上看 while hearing the phone; 面对面 turns the phone into the two-sided
    /// interpreter (FaceActivity).
    private fun buildAction() {
        val kind = cicada.listen.sourceKind
        if (kind == actionKind) return
        actionKind = kind
        actionHost.removeAllViews()
        val b = when (kind) {
            "mic" -> if (cicada.settings.speakBack) ui.roundButton(R.drawable.i_flip, L("面对面翻译")) { startActivity(Intent(this, FaceActivity::class.java)) } else null
            "playback" -> ui.roundButton(R.drawable.i_pip, L("在视频上看")) { watchOver() }
            else -> null
        }
        if (b != null) actionHost.addView(b)
        else actionHost.addView(View(this), FrameLayout.LayoutParams(ui.dp(48), ui.dp(48)))
    }

    /// 面对面 gets 我说 (hold, speak, release: the phone says it in their language) in place of
    /// 在视频上看, which has no video to go back to.
    private fun buildBottom() {
        val kind = cicada.listen.sourceKind
        if (kind == bottomKind) return
        bottomKind = kind
        bottomHost.removeAllViews()
        sayButton = null; sayLabel = null; sayHelper = null
        if (kind != "mic" || !cicada.settings.speakBack) {
            bottomHost.addView(if (kind == "playback") ui.bottomBar(
                ui.button(L("在视频上看"), "white", R.drawable.i_pip) { watchOver() },
                ui.button(L("结束"), "primary", R.drawable.i_stop) { end() })
                else ui.bottomBar(ui.button(L("结束"), "primary", R.drawable.i_stop) { end() }))
            return
        }
        val helper = ui.helper("").apply { gravity = android.view.Gravity.CENTER }
        val say = ui.button(L("按住说话"), "primary", R.drawable.i_mic, height = 64) {}
        val label = (0 until say.childCount).map { say.getChildAt(it) }.filterIsInstance<TextView>().first()
        say.setOnTouchListener { v, e ->
            when (e.actionMasked) {
                android.view.MotionEvent.ACTION_DOWN -> {
                    v.performHapticFeedback(android.view.HapticFeedbackConstants.VIRTUAL_KEY)
                    cicada.holdToSay(); updateSay(); true
                }
                android.view.MotionEvent.ACTION_UP, android.view.MotionEvent.ACTION_CANCEL -> {
                    v.performHapticFeedback(android.view.HapticFeedbackConstants.VIRTUAL_KEY)
                    cicada.releaseToSay(); updateSay(); true
                }
                else -> true
            }
        }
        // TalkBack's double tap is a click: press once to start, again to finish.
        say.setOnClickListener { if (cicada.listen.holding) cicada.releaseToSay() else cicada.holdToSay(); updateSay() }
        val bar = ui.bottomBar(ui.button(L("结束"), "white", height = 64) { end() }, say)
        (say.layoutParams as LinearLayout.LayoutParams).weight = 2.2f
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = ui.fade()
            addView(helper, LinearLayout.LayoutParams(-1, -2).apply { topMargin = ui.dp(24); leftMargin = ui.dp(16); rightMargin = ui.dp(16) })
            addView(bar.apply { background = null; setPadding(paddingLeft, ui.dp(8), paddingRight, paddingBottom) })
        }
        bottomHost.addView(box)
        sayButton = say; sayLabel = label; sayHelper = helper
        updateSay()
    }

    /// The button changes in place: rebuilding it under a finger would lose the hold.
    private fun updateSay() {
        val say = sayButton ?: return
        val app = cicada
        val l = app.listen
        val their = NotesViews.languageName(l.theirLanguage)
        val (text, live) = when {
            l.holding -> L("松开，说给对方") to true
            l.saying -> L("正在翻译…") to false
            app.voice.speaking -> L("正在读…") to true
            else -> L("按住说话") to false
        }
        sayLabel?.text = text
        say.contentDescription = text
        // The accent only while it's live (my turn, or the phone speaking); white on it is under
        // 4.5:1, so the label is ink then.
        say.background = ui.ripple(ui.rounded(if (live) Palette.accent else Palette.ink, 32), 32, dark = true)
        sayLabel?.setTextColor(if (live) Palette.ink else android.graphics.Color.WHITE)
        (0 until say.childCount).map { say.getChildAt(it) }.filterIsInstance<android.widget.ImageView>().firstOrNull()?.setColorFilter(if (live) Palette.ink else android.graphics.Color.WHITE)
        sayHelper?.text = l.sayProblem ?: L("松开后用 {lang} 读出来").replace("{lang}", their)
        sayHelper?.setTextColor(if (l.sayProblem != null) Palette.link else Palette.secondary)
    }

    override fun onSaveInstanceState(out: Bundle) { super.onSaveInstanceState(out); out.putInt("tab", tab) }

    override fun onResume() {
        super.onResume()
        if (!cicada.listen.listening && cicada.listen.pending == 0) { finish(); return }
        unobserve = cicada.observe(::render)
        shown = null
        render()
        cicada.main.postDelayed(tick, 1000)
    }

    override fun onPause() {
        super.onPause()
        unobserve?.invoke(); unobserve = null
        cicada.main.removeCallbacks(tick)
    }

    private fun render() {
        val app = cicada
        // Ended elsewhere (the notification, the floating window, Android's "stop sharing").
        if (!app.listen.listening && app.listen.pending == 0) { openRecord(); return }
        badgeText.text = NotesViews.status(app)
        buildBottom()
        buildAction()
        updateSay()
        sourceText.text = NotesViews.sourceLine(app)
        val key = NotesViews.liveKey(app) + tab + app.listen.spoken
        if (key == shown) return
        shown = key
        tabsHost.removeAllViews()
        tabsHost.addView(ui.tabs(listOf(L("实时纪要"), L("字幕")), tab, ink = true, track = Palette.card) { tab = it; render() }.apply { ui.lift(this, 1) })
        content.removeAllViews()
        NotesViews.endingStrip(ui, app)?.let { content.addView(it) }
        NotesViews.banner(ui, app) { switchToMic() }?.let { content.addView(it) }
        if (tab == 1) {
            content.addView(ui.spacer(), LinearLayout.LayoutParams(-1, 0, 1f))
            content.addView(NotesViews.bubbles(ui, app, 12))
            scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
        } else {
            val card = NotesViews.notesBody(ui, app.notes.notes, app.notes.status, app.listen.listening).apply {
                background = ui.rounded(Palette.card, 22)
                setPadding(ui.dp(18), ui.dp(18), ui.dp(18), ui.dp(20))
            }
            content.addView(card)
        }
    }

    /// Back to the app underneath (the video): the floating window shows there. Without the
    /// permission for it, the guide asks for it (and walks through Android's unlock when needed).
    private fun watchOver() {
        val app = cicada
        if (!app.canOverlay) { OverlayGuideActivity.open(this, watch = true); return }
        // Asked for now: show it for this meeting even if 悬浮窗 is off in 设置, without changing that.
        app.overlayThisMeeting = true
        app.overlayClosed = false
        moveTaskToBack(true)
    }

    /// The Mac's requestStop: a meeting with lines ends only after asking, 继续记录 the safe
    /// choice; an empty one just stops.
    private fun end() {
        val s = cicada.listen.sessionId?.let { cicada.store.get(it) }
        if (s == null || s.lines.isEmpty() || !cicada.listen.listening) { endNow(); return }
        ui.confirm(this, L("结束这场会议？"), LF("已记录 %@ · %lld 句。结束后停止收听，并整理一份完整版纪要。", Languages.clock(s.durationSeconds), s.lines.size),
                   ok = L("结束会议"), cancel = L("继续记录")) { endNow() }
    }

    private fun endNow() {
        val id = cicada.listen.sessionId
        cicada.stopListening {
            if (id != null && cicada.store.get(id) != null) startActivity(Intent(this, RecordActivity::class.java).putExtra("id", id))
            finish()
        }
    }

    private fun openRecord() {
        val id = cicada.listen.sessionId
        if (id != null && cicada.store.get(id) != null && !isFinishing) startActivity(Intent(this, RecordActivity::class.java).putExtra("id", id))
        finish()
    }

    /// Nothing heard from the phone: start again from the microphone.
    private fun switchToMic() {
        val app = cicada
        app.settings.source = "mic"; app.saveSettings()
        app.stopListening { app.startListening(app, "mic") }
    }
}
