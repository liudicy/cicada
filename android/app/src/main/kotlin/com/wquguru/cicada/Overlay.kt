package com.wquguru.cicada

import android.annotation.SuppressLint
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import cicada.Log
import cicada.Strings.L
import kotlin.math.abs
import kotlin.math.hypot

/// The floating window over other apps while listening, in three shapes: live notes (a card),
/// the subtitle bar (dark, along the bottom, for reading over video), or collapsed to a small
/// round bubble that drags anywhere and closes when dropped on the × target.
///
/// Like the Mac's notes panel it never takes focus (FLAG_NOT_FOCUSABLE: the keyboard and back
/// button stay with the app underneath) and stays out of screenshots and recordings
/// (FLAG_SECURE) unless 共享屏幕时让对方看到 is on, which shows a badge.
class Overlay(private val app: CicadaApp) {
    private val wm = app.getSystemService(WindowManager::class.java)
    private val ui = Ui(app)
    private var root: FrameLayout? = null
    private var params: WindowManager.LayoutParams? = null
    private var dismissTarget: View? = null
    private var clockText: TextView? = null
    private var live: LinearLayout? = null
    private var notes: FrameLayout? = null
    private var shownKey: String? = null
    private val tick = object : Runnable {
        override fun run() { if (root != null) { clockText?.text = NotesViews.clock(app); render(); NotesViews.tickEnding(root, app); app.main.postDelayed(this, 1000) } }
    }

    /// Shown by a debug command regardless of the rules (screenshots of it over Cicada itself).
    var forced = false
    /// Collapsed to the bubble (reset when a meeting starts).
    var collapsed = false
    val shown get() = root != null
    private val subtitles get() = app.settings.view == "subtitles"
    private val mode get() = if (collapsed) "bubble" else if (subtitles) "subtitles" else "notes"
    /// Where the person dragged the card and the subtitle bar, kept while Cicada runs.
    private val placed = HashMap<String, Pair<Int, Int>>()

    fun show() {
        if (root != null || !app.canOverlay) return
        build()
        app.main.removeCallbacks(tick)
        app.main.postDelayed(tick, 1000)
    }

    fun hide() {
        root?.let { try { wm.removeView(it) } catch (_: Exception) {} }
        root = null
        shownKey = null
        hideTarget()
        app.main.removeCallbacks(tick)
    }

    /// The shape changed (notes ↔ subtitles ↔ bubble, or the capture setting): build it again in place.
    fun rebuild() { if (root != null) { hide(); show() } }

    private fun flags(): Int {
        var f = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
        if (!app.settings.showInCapture) f = f or WindowManager.LayoutParams.FLAG_SECURE
        return f
    }

    private fun build() {
        val dm = app.resources.displayMetrics
        // Phone-sized on a tablet: a card and a subtitle bar, not a banner across the screen.
        val full = dm.widthPixels - ui.dp(16)
        val width = when (mode) { "bubble" -> ViewGroup.LayoutParams.WRAP_CONTENT; "subtitles" -> minOf(full, ui.dp(720)); else -> minOf(full, ui.dp(420)) }
        val left = if (width > 0) (dm.widthPixels - width) / 2 else 0
        val p = WindowManager.LayoutParams(width, ViewGroup.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, flags(), PixelFormat.TRANSLUCENT).apply {
            title = "Cicada floating window"
            when (mode) {
                // The subtitle bar hangs from the bottom edge, above the navigation bar, so a long
                // line grows upwards instead of off the screen.
                "subtitles" -> { gravity = Gravity.BOTTOM or Gravity.START; x = left; y = ui.dp(64) }
                "bubble" -> { gravity = Gravity.TOP or Gravity.START; x = dm.widthPixels - ui.dp(76); y = (dm.heightPixels * 0.45).toInt() }
                else -> { gravity = Gravity.TOP or Gravity.START; x = left; y = (dm.heightPixels * 0.32).toInt() }
            }
            placed[mode]?.let { (px, py) -> x = px; y = py }
        }
        params = p
        val frame = (if (mode == "bubble") FrameLayout(app) else DragFrame(p, fromBottom = mode == "subtitles"))
            .apply { setPadding(ui.dp(4), ui.dp(4), ui.dp(4), ui.dp(8)) }
        when (mode) {
            "bubble" -> buildBubble(frame, p)
            "subtitles" -> buildSubtitles(frame, p)
            else -> buildNotes(frame, p)
        }
        // A video in picture-in-picture moves out of the way of keep-clear areas (Android 13+),
        // so 在视频上看 doesn't hide the very video it is about. The bubble is small enough to sit on it.
        if (mode != "bubble" && android.os.Build.VERSION.SDK_INT >= 33) frame.isPreferKeepClear = true
        try {
            wm.addView(frame, p)
            root = frame
            Log.d("overlay: shown $mode secure=${!app.settings.showInCapture}")
        } catch (e: Exception) {
            Log.d("overlay: refused ${e.javaClass.simpleName}")
            return
        }
        render()
    }

    private fun clock(color: Int): TextView = ui.text(NotesViews.clock(app), 14f, color, bold = true).also { clockText = it }

    private fun header(dark: Boolean): LinearLayout {
        val fg = if (dark) Palette.onScrim else Palette.body
        return LinearLayout(app).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(ui.dp(12), 0, 0, 0)
            addView(ui.dot(Palette.accent, 8))
            addView(clock(if (dark) Palette.onScrim else Palette.ink), LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(8) })
            if (app.settings.showInCapture) addView(ui.badge(L("对方可见")), LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(8) })
            addView(ui.spacer())
            addView(if (subtitles) ui.iconButton(R.drawable.i_list, L("换成纪要"), fg, 20, dark) { app.setView("notes") }
                    else ui.iconButton(R.drawable.i_captions, L("换成字幕条"), fg, 22, dark) { app.setView("subtitles") })
            addView(ui.iconButton(R.drawable.i_chevron_down, L("收起成小圆点"), fg, 22, dark) { collapsed = true; rebuild() })
        }
    }

    private fun buildNotes(frame: FrameLayout, p: WindowManager.LayoutParams) {
        val card = LinearLayout(app).apply {
            orientation = LinearLayout.VERTICAL
            background = ui.rounded(Palette.card, 24, Color.parseColor("#1015171C"))
            elevation = ui.dp(10).toFloat()
            setPadding(ui.dp(6), ui.dp(6), ui.dp(6), ui.dp(16))
        }
        val handle = FrameLayout(app).apply {
            addView(View(app).apply { background = ui.rounded(Palette.outline, 2) }, FrameLayout.LayoutParams(ui.dp(32), ui.dp(4), Gravity.CENTER))
        }
        card.addView(handle, LinearLayout.LayoutParams(-1, ui.dp(12)))
        val head = header(dark = false)
        card.addView(head)
        live = LinearLayout(app).apply { orientation = LinearLayout.VERTICAL }; notes = FrameLayout(app)
        card.addView(live, LinearLayout.LayoutParams(-1, -2).apply { leftMargin = ui.dp(10); rightMargin = ui.dp(10) })
        card.addView(notes, LinearLayout.LayoutParams(-1, -2).apply { leftMargin = ui.dp(16); rightMargin = ui.dp(16); topMargin = ui.dp(14) })
        frame.addView(card)
    }

    private fun buildSubtitles(frame: FrameLayout, p: WindowManager.LayoutParams) {
        val bar = LinearLayout(app).apply {
            orientation = LinearLayout.VERTICAL
            background = ui.rounded(Palette.scrim, 22)
            elevation = ui.dp(10).toFloat()
            setPadding(ui.dp(4), ui.dp(2), ui.dp(4), ui.dp(16))
        }
        val head = header(dark = true)
        bar.addView(head)
        live = LinearLayout(app).apply { orientation = LinearLayout.VERTICAL }; notes = null
        bar.addView(live, LinearLayout.LayoutParams(-1, -2).apply { leftMargin = ui.dp(12); rightMargin = ui.dp(16) })
        frame.addView(bar)
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun buildBubble(frame: FrameLayout, p: WindowManager.LayoutParams) {
        val column = LinearLayout(app).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL }
        val bubble = FrameLayout(app).apply {
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Palette.card); setStroke(ui.dp(3), Palette.accent) }
            elevation = ui.dp(8).toFloat()
            addView(ImageView(app).apply {
                setImageDrawable(app.getDrawable(R.mipmap.ic_launcher))
                clipToOutline = true
                background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Palette.card) }
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, FrameLayout.LayoutParams(ui.dp(46), ui.dp(46), Gravity.CENTER))
            contentDescription = L("知了") + " · " + L("正在听")
        }
        column.addView(bubble, LinearLayout.LayoutParams(ui.dp(60), ui.dp(60)))
        val chip = ui.text(NotesViews.clock(app), 12f, Color.WHITE, bold = true).apply {
            background = ui.rounded(Palette.ink, 10); setPadding(ui.dp(8), ui.dp(2), ui.dp(8), ui.dp(2))
        }
        clockText = chip
        column.addView(chip, LinearLayout.LayoutParams(-2, -2).apply { topMargin = ui.dp(4) })
        frame.addView(column)
        live = null; notes = null
        // A tap expands it; a drag moves it, and dropping it on the × closes the floating window.
        var downX = 0f; var downY = 0f; var startX = 0; var startY = 0; var moved = false
        bubble.setOnTouchListener { _, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> { downX = e.rawX; downY = e.rawY; startX = p.x; startY = p.y; moved = false; true }
                MotionEvent.ACTION_MOVE -> {
                    if (!moved && hypot(e.rawX - downX, e.rawY - downY) > ui.dp(8)) { moved = true; showTarget() }
                    if (moved) {
                        p.x = startX + (e.rawX - downX).toInt(); p.y = startY + (e.rawY - downY).toInt()
                        try { wm.updateViewLayout(frame, p) } catch (_: Exception) {}
                        highlightTarget(overTarget(e.rawX, e.rawY))
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) { collapsed = false; rebuild() }
                    else if (overTarget(e.rawX, e.rawY)) { app.overlayClosed = true; forced = false; hide(); app.changed() }
                    else snapToEdge(frame, p)
                    hideTarget()
                    true
                }
                else -> { hideTarget(); false }
            }
        }
        bubble.setOnClickListener { collapsed = false; rebuild() } // TalkBack's double tap
    }

    /// Bubbles rest against the nearer side.
    private fun snapToEdge(frame: View, p: WindowManager.LayoutParams) {
        val dm = app.resources.displayMetrics
        p.x = if (p.x + ui.dp(34) < dm.widthPixels / 2) ui.dp(8) else dm.widthPixels - ui.dp(76)
        try { wm.updateViewLayout(frame, p) } catch (_: Exception) {}
    }

    private fun targetCenter(): Pair<Float, Float> {
        val dm = app.resources.displayMetrics
        return dm.widthPixels / 2f to dm.heightPixels - ui.dp(120).toFloat()
    }

    private fun overTarget(x: Float, y: Float): Boolean {
        val (cx, cy) = targetCenter()
        return abs(x - cx) < ui.dp(64) && abs(y - cy) < ui.dp(64)
    }

    private fun showTarget() {
        if (dismissTarget != null) return
        val view = LinearLayout(app).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            addView(FrameLayout(app).apply {
                background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Palette.scrim) }
                addView(ui.icon(R.drawable.i_close, 24, Color.WHITE), FrameLayout.LayoutParams(ui.dp(24), ui.dp(24), Gravity.CENTER))
            }, LinearLayout.LayoutParams(ui.dp(56), ui.dp(56)))
            addView(ui.text(L("拖到这里关掉悬浮窗，后台继续听"), 13f, Color.WHITE).apply {
                background = ui.rounded(Palette.scrim, 12); setPadding(ui.dp(10), ui.dp(4), ui.dp(10), ui.dp(4))
            }, LinearLayout.LayoutParams(-2, -2).apply { topMargin = ui.dp(8) })
        }
        val p = WindowManager.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, flags() or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE, PixelFormat.TRANSLUCENT).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            y = ui.dp(64)
        }
        try { wm.addView(view, p); dismissTarget = view } catch (_: Exception) {}
    }

    private fun highlightTarget(on: Boolean) {
        val circle = (dismissTarget as? LinearLayout)?.getChildAt(0) ?: return
        circle.scaleX = if (on) 1.2f else 1f; circle.scaleY = circle.scaleX
    }

    private fun hideTarget() {
        dismissTarget?.let { try { wm.removeView(it) } catch (_: Exception) {} }
        dismissTarget = null
    }

    /// The card or the subtitle bar, dragged from anywhere on it: a finger that moves past the
    /// touch slop takes the gesture from the buttons underneath, so taps still reach them. (A
    /// listener on the header alone never moved it: it turned the first touch down, and Android
    /// then sends that view nothing more of the gesture.)
    @SuppressLint("ViewConstructor", "ClickableViewAccessibility")
    private inner class DragFrame(private val p: WindowManager.LayoutParams, private val fromBottom: Boolean) : FrameLayout(app) {
        private val slop = ViewConfiguration.get(app).scaledTouchSlop
        private var downX = 0f; private var downY = 0f; private var startX = 0; private var startY = 0
        private var dragging = false

        private fun down(e: MotionEvent) { downX = e.rawX; downY = e.rawY; startX = p.x; startY = p.y; dragging = false }

        override fun onInterceptTouchEvent(e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> down(e)
                MotionEvent.ACTION_MOVE -> if (!dragging && hypot(e.rawX - downX, e.rawY - downY) > slop) dragging = true
            }
            return dragging
        }

        override fun onTouchEvent(e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> down(e)
                MotionEvent.ACTION_MOVE -> {
                    if (!dragging && hypot(e.rawX - downX, e.rawY - downY) > slop) dragging = true
                    if (dragging) move(e)
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (dragging) placed[mode] = p.x to p.y
                    dragging = false
                }
            }
            return true
        }

        /// Follows the finger, kept on the screen and clear of the status and gesture bars.
        private fun move(e: MotionEvent) {
            val dm = app.resources.displayMetrics
            val edge = ui.dp(28)
            p.x = (startX + (e.rawX - downX).toInt()).coerceIn(0, maxOf(0, dm.widthPixels - width))
            p.y = (startY + (if (fromBottom) -1 else 1) * (e.rawY - downY).toInt()).coerceIn(edge, maxOf(edge, dm.heightPixels - height - edge))
            try { wm.updateViewLayout(this, p) } catch (_: Exception) {}
        }
    }

    fun refresh() { if (root != null) render() }

    private fun render() {
        // Rebuilt only when what it shows changed: a view replaced under a finger loses the tap.
        val key = NotesViews.liveKey(app) + mode + app.settings.showInCapture
        if (key == shownKey) return
        shownKey = key
        clockText?.text = NotesViews.clock(app)
        val dark = mode == "subtitles"
        live?.let { box ->
            box.removeAllViews()
            val line = NotesViews.currentLines(app).lastOrNull()
            val banner = NotesViews.banner(ui, app, null)
            if (dark) NotesViews.endingBarText(app)?.let {
                box.addView(ui.text(it, 13f, Palette.accentPale, bold = true).apply { tag = NotesViews.ENDING_BAR }, ui.lp().apply { bottomMargin = ui.dp(6) })
            } else NotesViews.endingStrip(ui, app, compact = true)?.let { box.addView(it, ui.lp().apply { bottomMargin = ui.dp(8) }) }
            when {
                banner != null && line == null -> box.addView(if (dark) ui.text((banner as LinearLayout).let { (it.getChildAt(1) as TextView).text }, 15f, Color.WHITE) else banner)
                line == null -> box.addView(ui.text(L("等有人说话…"), 15f, if (dark) Palette.onScrim else Palette.secondary).apply { setPadding(ui.dp(if (dark) 0 else 14), ui.dp(10), 0, ui.dp(10)) })
                dark -> {
                    val col = ui.stack(4)
                    if (!line.dst.isNullOrEmpty() && line.dst != line.src) col.addView(ui.text(line.src, 13f, Palette.onScrim, lines = 2))
                    col.addView(ui.text(line.dst ?: line.src, 20f, Color.WHITE, bold = true, lines = 3).apply { leading(1.2f) })
                    box.addView(col)
                }
                else -> box.addView(NotesViews.liveCard(ui, app, line, 18f, Palette.ground, lines = 3, dots = false).apply { setPadding(ui.dp(14), ui.dp(12), ui.dp(14), ui.dp(12)) })
            }
        }
        notes?.let { box ->
            box.removeAllViews()
            val column = ui.stack(10)
            column.addView(NotesViews.notesBody(ui, app.notes.notes, app.notes.status, app.listen.listening, compact = true))
            val privacy = if (app.settings.showInCapture) L("共享屏幕时对方能看到") else L("截图和录屏里看不到")
            val fresh = NotesViews.updated(app.notes.notes.updatedAt)
            column.addView(LinearLayout(app).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                if (!app.settings.showInCapture) addView(ui.icon(R.drawable.i_eye_off, 14, Palette.secondary), LinearLayout.LayoutParams(ui.dp(14), ui.dp(14)).apply { rightMargin = ui.dp(6) })
                addView(ui.text(listOfNotNull(privacy, fresh).joinToString(" · "), 12f, Palette.secondary, lines = 1))
            }, ui.lp(top = 12))
            box.addView(column)
        }
    }

    /// For the debug receiver: the window as Android has it.
    fun describe(): Map<String, Any?> = mapOf(
        "shown" to (root != null),
        "mode" to if (root != null) mode else null,
        "secure" to params?.let { it.flags and WindowManager.LayoutParams.FLAG_SECURE != 0 },
        "focusable" to params?.let { it.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE == 0 },
        "view" to app.settings.view,
        "x" to params?.x, "y" to params?.y,
    )
}
