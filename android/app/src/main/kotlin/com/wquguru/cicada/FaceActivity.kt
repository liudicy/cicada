package com.wquguru.cicada

import android.app.Activity
import android.os.Bundle
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import cicada.Strings.L
import cicada.TranscriptLine

/// 面对面翻译: the phone flat between two people. The top half is turned to the other side and
/// shows the newest line in their language (what I said, translated; or what they said, so they
/// see it was heard); the bottom half shows it in mine. Hold the button to speak: on release the
/// phone reads my words aloud in their language (only ever a translation: ListenEngine.speakable).
class FaceActivity : Activity() {
    private lateinit var ui: Ui
    private lateinit var theirLabel: TextView
    private lateinit var theirText: TextView
    private lateinit var myLabel: TextView
    private lateinit var myText: TextView
    private lateinit var status: TextView
    private lateinit var hint: TextView
    private lateinit var hold: FrameLayout
    private lateinit var holdIcon: ImageView
    private var shown: String? = null
    private var unobserve: (() -> Unit)? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ui = Ui(this)
        window.statusBarColor = Palette.ground
        window.navigationBarColor = Palette.ground
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        theirLabel = ui.text("", 13f, Palette.secondary)
        theirText = ui.text("", 28f, Palette.ink, bold = true).apply { leading(1.3f) }
        myLabel = ui.text("", 13f, Palette.secondary)
        myText = ui.text("", 22f, Palette.ink).apply { leading(1.45f) }
        status = ui.text("", 13f, Palette.secondary).apply { gravity = Gravity.CENTER; accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }
        hint = ui.text("", 14f, Palette.secondary).apply { gravity = Gravity.CENTER }
        val theirs = ui.stack(12, theirLabel, theirText).apply {
            background = ui.rounded(Palette.card, 28)
            setPadding(ui.dp(24), ui.dp(24), ui.dp(24), ui.dp(24))
            rotation = 180f
        }
        val mine = ui.stack(12, myLabel, myText).apply {
            background = ui.rounded(Palette.card, 28)
            setPadding(ui.dp(24), ui.dp(24), ui.dp(24), ui.dp(24))
        }
        holdIcon = ImageView(this).apply { setImageDrawable(ui.drawable(R.drawable.i_mic, android.graphics.Color.WHITE)); importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }
        hold = FrameLayout(this).apply {
            addView(holdIcon, FrameLayout.LayoutParams(ui.dp(36), ui.dp(36), Gravity.CENTER))
            contentDescription = L("按住说话")
            isClickable = true; isFocusable = true
            elevation = ui.dp(6).toFloat()
        }
        hold.setOnTouchListener { v, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> { v.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY); cicada.holdToSay(); update(); true }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> { v.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY); cicada.releaseToSay(); update(); true }
                else -> true
            }
        }
        // TalkBack's double tap is a click: once to start, again to finish.
        hold.setOnClickListener { if (cicada.listen.holding) cicada.releaseToSay() else cicada.holdToSay(); update() }
        val close = ui.roundButton(R.drawable.i_close, L("收起")) { finish() }
        val middle = FrameLayout(this).apply {
            addView(status, FrameLayout.LayoutParams(-1, -2, Gravity.CENTER))
            addView(close, FrameLayout.LayoutParams(ui.dp(48), ui.dp(48), Gravity.END or Gravity.CENTER_VERTICAL))
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(ui.dp(16), ui.dp(12), ui.dp(16), ui.dp(20))
            addView(theirs, LinearLayout.LayoutParams(-1, 0, 1.1f))
            addView(middle, LinearLayout.LayoutParams(-1, ui.dp(64)))
            addView(mine, LinearLayout.LayoutParams(-1, 0, 0.8f))
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                setPadding(0, ui.dp(28), 0, 0)
                clipToPadding = false; clipChildren = false
                addView(hold, LinearLayout.LayoutParams(ui.dp(104), ui.dp(104)))
                addView(hint, LinearLayout.LayoutParams(-1, -2).apply { topMargin = ui.dp(18) })
            }, LinearLayout.LayoutParams(-1, -2))
            clipChildren = false
        }
        // The system bars' insets go on the outer frame: fitsSystemWindows replaces a view's own padding.
        setContentView(FrameLayout(this).apply {
            setBackgroundColor(Palette.ground)
            fitsSystemWindows = true
            addView(root, FrameLayout.LayoutParams(-1, -1))
        })
    }

    override fun onResume() {
        super.onResume()
        if (!cicada.listen.listening || cicada.listen.sourceKind != "mic") { finish(); return }
        unobserve = cicada.observe(::update)
        shown = null
        update()
    }

    override fun onPause() { super.onPause(); unobserve?.invoke(); unobserve = null }

    private fun update() {
        val app = cicada
        val l = app.listen
        if (!l.listening) { finish(); return }
        val their = l.theirLanguage
        val mineLang = app.settings.targetCode
        val line: TranscriptLine? = NotesViews.currentLines(app).lastOrNull()
        val key = listOf(line?.id, line?.src, line?.dst, l.holding, l.saying, app.voice.speaking, l.sayProblem, their).joinToString("|")
        if (key == shown) return
        shown = key
        // What each side reads, in their own language.
        val mine = line?.speaker == "me"
        val translated = line?.dst?.takeIf { it.isNotEmpty() && it != line.src }
        theirLabel.text = NotesViews.languageName(their)
        theirText.text = when { line == null -> "…"; mine -> translated ?: "…"; else -> line.src }
        myLabel.text = (if (line == null || mine) L("你") else L("对方")) + " · " + NotesViews.languageName(mineLang)
        myText.text = when { line == null -> L("按住下面的按钮说话，松开后对方会听到译文"); mine -> line.src; else -> translated ?: line.src }
        myText.setTextColor(if (line == null) Palette.secondary else Palette.ink)
        val live = l.holding || app.voice.speaking
        status.text = l.sayProblem ?: when {
            l.holding -> L("正在听你说，念的时候不收音")
            l.saying -> L("正在翻译…")
            app.voice.speaking -> L("正在读…")
            else -> L("正在听对方说")
        }
        status.setTextColor(if (l.sayProblem != null) Palette.link else Palette.secondary)
        hint.text = if (l.holding) L("松开，说给对方") else L("松开后用 {lang} 读出来").replace("{lang}", NotesViews.languageName(their))
        hold.background = ui.ripple(ui.rounded(if (live) Palette.accent else Palette.ink, 52), 52, dark = true)
        holdIcon.setColorFilter(if (live) Palette.ink else android.graphics.Color.WHITE)
        // The ring says "I'm listening to you" while held.
        hold.foreground = if (l.holding) ui.rounded(0, 52, 0x40E8552B, 10) else null
    }
}
