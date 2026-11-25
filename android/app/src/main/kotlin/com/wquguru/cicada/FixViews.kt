package com.wquguru.cicada

import android.app.Activity
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.text.SpannableString
import android.text.Spanned
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.ReplacementSpan
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import cicada.Correction
import cicada.LineFix
import cicada.LiveFixes
import cicada.Languages
import cicada.Session
import cicada.Strings.L
import cicada.Strings.LF
import cicada.TranscriptLine

/// 改正听错的词 on screen (the Mac's FixViews.swift and the fixing parts of NotesViews.swift): the
/// fixed words dotted, what each was heard as with 改回, the 这样改对吗？ card, the banner over a
/// finished meeting, 改这句… and the 撤销 message. A phone has no pointer to hover with: a line's
/// fixed words open with a long press (the record) or show under the newest line (正在听).
object FixViews {
    /// A fixed word: drawn as it is, with a dotted line under it (Android has no dotted underline).
    class Dotted(private val color: Int, private val dp: Float) : ReplacementSpan() {
        override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
            if (fm != null) paint.getFontMetricsInt(fm)
            return Math.round(paint.measureText(text, start, end))
        }

        override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
            canvas.drawText(text, start, end, x, y.toFloat(), paint)
            val line = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = this@Dotted.color; style = Paint.Style.STROKE; strokeWidth = 1.3f * dp
                pathEffect = DashPathEffect(floatArrayOf(1.6f * dp, 2.2f * dp), 0f)
            }
            val at = y + 3.2f * dp
            canvas.drawLine(x, at, x + paint.measureText(text, start, end), at, line)
        }
    }

    /// The line as shown, each fixed word dotted, words waiting for the user (这样改对吗？) washed pale.
    fun text(ui: Ui, line: TranscriptLine, prefix: String = ""): CharSequence {
        val fixes = line.fixes ?: return prefix + line.src
        val a = Correction.apply(fixes, line.src)
        val s = SpannableString(prefix + a.text)
        val dp = ui.context.resources.displayMetrics.density
        for (m in a.marks) s.setSpan(Dotted(Palette.tertiary, dp), prefix.length + m.first, prefix.length + m.last + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        for (f in fixes) if (f.ask == true) {
            val i = a.text.indexOf(f.from)
            if (i >= 0) s.setSpan(BackgroundColorSpan(Palette.accentPale), prefix.length + i, prefix.length + i + f.from.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        return s
    }

    /// "听成 莫拉 → Morpho" with the grey parts grey.
    private fun heardAs(from: String, to: String): CharSequence {
        val head = L("听成") + " "
        val arrow = " → "
        val s = SpannableString(head + from + arrow + to)
        s.setSpan(ForegroundColorSpan(Palette.tertiary), 0, head.length, 0)
        s.setSpan(ForegroundColorSpan(Palette.tertiary), head.length + from.length, head.length + from.length + arrow.length, 0)
        return s
    }

    /// Under a line: each applied fix, what it was heard as, and 改回.
    fun fixedWords(ui: Ui, lineId: String, fixes: List<LineFix>, onRevert: (String, LineFix) -> Unit): View? {
        val applied = fixes.filter { it.applied }
        if (applied.isEmpty()) return null
        val box = ui.stack(6)
        for (f in applied) {
            val (from, to) = Correction.label(f)
            box.addView(LinearLayout(ui.context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                background = ui.rounded(Palette.ground, 8)
                setPadding(ui.dp(10), 0, ui.dp(2), 0)
                addView(ui.text(heardAs(from, to), 13f, Palette.ink, lines = 1))
                addView(ui.text(L("改回"), 13f, Palette.link, bold = true).apply {
                    gravity = Gravity.CENTER
                    minHeight = ui.dp(36)
                    setPadding(ui.dp(10), 0, ui.dp(10), 0)
                    ui.tappable(this, 8) { onRevert(lineId, f) }
                })
            }, LinearLayout.LayoutParams(-2, -2))
        }
        return box
    }

    /// 这样改对吗？: a name sound can't check, asked about once. 对 fixes every line waiting on it and
    /// adds it to the word list; × (稍后再看) asks again after the meeting.
    fun confirmCard(ui: Ui, a: LiveFixes.Asking, onAnswer: (Boolean) -> Unit, onLater: (() -> Unit)?): View {
        val (from, to) = Correction.label(a.fix)
        val card = ui.stack(0)
        card.background = ui.rounded(Palette.card, 16, Palette.line, 1)
        card.setPadding(ui.dp(14), ui.dp(10), ui.dp(6), ui.dp(12))
        card.addView(LinearLayout(ui.context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(ui.text(L("这样改对吗？"), 15f, Palette.ink, bold = true), ui.weight())
            if (a.of > 1) addView(ui.text("1 / ${a.of}", 13f, Palette.tertiary).apply { fontFeatureSettings = "tnum" })
            if (onLater != null) addView(ui.iconButton(R.drawable.i_close, L("稍后再看"), Palette.tertiary, 18) { onLater() })
            else addView(View(ui.context), LinearLayout.LayoutParams(ui.dp(8), 1))
        })
        card.addView(ui.text(L("确认后整场一起改，以后也这样改"), 12f, Palette.tertiary).apply { setPadding(0, 0, ui.dp(8), 0) })
        val change = SpannableString("$from → $to")
        change.setSpan(ForegroundColorSpan(Palette.tertiary), from.length, from.length + 3, 0)
        change.setSpan(android.text.style.StyleSpan(android.graphics.Typeface.BOLD), from.length + 3, change.length, 0)
        card.addView(ui.text(change, 17f, Palette.ink), ui.lp(top = 8))
        card.addView(ui.text("${Languages.clock(a.line.t)} · ${a.line.src}", 12f, Palette.tertiary, lines = 1).apply {
            ellipsize = android.text.TextUtils.TruncateAt.END; setPadding(0, 0, ui.dp(8), 0)
        }, ui.lp(top = 2))
        card.addView(LinearLayout(ui.context).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(ui.button(L("对"), "primary", height = 40) { onAnswer(true) }, ui.weight())
            addView(ui.button(L("不对"), "quiet", height = 40) { onAnswer(false) }, ui.weight().apply { leftMargin = ui.dp(8) })
            setPadding(0, 0, ui.dp(8), 0)
        }, ui.lp(top = 10))
        return card
    }

    /// Above a finished meeting's transcript: how many words were fixed, and the ones waiting for the
    /// user, one at a time (对 / 不对 / 改成…). Nothing when there was nothing to fix.
    fun reviewBanner(ui: Ui, fixes: LiveFixes, s: Session, onShow: (String) -> Unit, onEdit: (TranscriptLine, String) -> Unit): View? {
        val waiting = fixes.pending(s.id)
        val fixed = fixes.store.lines(s.id).sumOf { l -> (l.fixes ?: emptyList()).count { it.applied } }
        val first = waiting.firstOrNull()
        if (first == null) return if (fixed > 0) ui.text(LF("改了 %lld 处听错的词", fixed), 13f, Palette.tertiary) else null
        val (from, to) = Correction.label(first.fix)
        val box = ui.stack(8)
        box.background = ui.rounded(Color.parseColor("#FEF6F2"), 16, Palette.accentPale, 1)
        box.setPadding(ui.dp(14), ui.dp(12), ui.dp(14), ui.dp(12))
        val head = ui.stack(2,
            ui.text(LF("改了 %lld 处听错的词，%lld 处等你确认", fixed, waiting.size), 14f, Palette.ink, medium = true),
            ui.text("$from → $to？ · ${Languages.clock(first.line.t)}", 13f, Palette.secondary))
        ui.tappable(head, 8) { onShow(first.line.id) }
        box.addView(head)
        box.addView(LinearLayout(ui.context).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(ui.button(L("对"), "primary", height = 40) { fixes.answer(first.fix, true, s.id) }, ui.weight())
            addView(ui.button(L("不对"), "white", height = 40) { fixes.answer(first.fix, false, s.id) }, ui.weight().apply { leftMargin = ui.dp(8) })
            addView(ui.button(L("改成…"), "white", height = 40) {
                onEdit(first.line, Correction.apply((first.line.fixes ?: emptyList()).filter { it.applied }, first.line.src).text)
            }, ui.weight().apply { leftMargin = ui.dp(8) })
        }, ui.lp(top = 4))
        return box
    }

    /// A long press on a line in the record: its fixed words with 改回, and 改这句….
    fun lineSheet(activity: Activity, ui: Ui, app: CicadaApp, sessionId: String, line: TranscriptLine) {
        lateinit var d: android.app.Dialog
        val box = ui.stack(10)
        box.addView(ui.text(text(ui, line), 16f, Palette.ink).apply { leading(1.5f); setPadding(ui.dp(8), 0, ui.dp(8), 0) })
        fixedWords(ui, line.id, line.fixes ?: emptyList()) { id, f -> d.dismiss(); app.fixes.revert(f, id, sessionId) }
            ?.let { box.addView(it, ui.lp().apply { leftMargin = ui.dp(8) }) }
        box.addView(ui.sheetAction(R.drawable.i_edit, L("改这句…")) { d.dismiss(); edit(activity, ui, app, sessionId, line, line.shown) })
        d = ui.sheet(activity, null, box)
        d.show()
    }

    /// 改这句…: the line as shown, to rewrite. What changed becomes the user's own fix, on every line
    /// heard the same way or only this one, and (made everywhere) joins the word list.
    fun edit(activity: Activity, ui: Ui, app: CicadaApp, sessionId: String, line: TranscriptLine, start: String) {
        lateinit var d: android.app.Dialog
        val field = android.widget.EditText(activity).apply {
            setText(start)
            setSelection(start.length)
            setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 16f)
            background = ui.rounded(Palette.ground, 16)
            setPadding(ui.dp(16), ui.dp(12), ui.dp(16), ui.dp(12))
            minHeight = ui.dp(52)
        }
        val heard = ui.text("", 13f, Palette.secondary)
        val everywhere = android.widget.RadioButton(activity).apply { id = View.generateViewId(); textSize = 14f; buttonTintList = android.content.res.ColorStateList.valueOf(Palette.ink); isChecked = true }
        val once = android.widget.RadioButton(activity).apply { id = View.generateViewId(); textSize = 14f; buttonTintList = android.content.res.ColorStateList.valueOf(Palette.ink); text = L("只改这一处") }
        val scope = android.widget.RadioGroup(activity).apply { addView(everywhere); addView(once) }
        val keep = android.widget.CheckBox(activity).apply { text = L("记进词表，以后自动改"); textSize = 14f; buttonTintList = android.content.res.ColorStateList.valueOf(Palette.ink); isChecked = true }
        fun update() {
            val same = app.fixes.sameHeard(line.id, sessionId, field.text.toString())
            heard.visibility = if (same == null) View.GONE else View.VISIBLE
            // Only a word for a word can teach the list: an added or dropped word can't.
            keep.visibility = if (same != null && same.swap) View.VISIBLE else View.GONE
            scope.visibility = if (same != null && same.count > 1) View.VISIBLE else View.GONE
            if (same != null) {
                heard.text = LF("听成 %@", same.heard)
                everywhere.text = LF("整场听成 %@ 的 %lld 处都改", same.heard, same.count)
            }
            // Only a change made everywhere teaches the word list.
            keep.isEnabled = same == null || same.count <= 1 || everywhere.isChecked
        }
        field.addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: android.text.Editable?) = update()
        })
        scope.setOnCheckedChangeListener { _, _ -> update() }
        update()
        val body = ui.stack(8, field, heard, scope, keep)
        body.addView(LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(ui.button(L("取消"), "quiet") { d.dismiss() }, ui.weight())
            addView(ui.button(L("改成"), "primary") {
                d.dismiss()
                val same = app.fixes.sameHeard(line.id, sessionId, field.text.toString()) ?: return@button
                val all = same.count <= 1 || everywhere.isChecked
                app.background.execute { app.fixes.edit(line.id, sessionId, field.text.toString(), everywhere = all, keep = keep.isChecked && all && same.swap) }
            }, ui.weight().apply { leftMargin = ui.dp(10) })
        }, ui.lp(top = 8))
        d = ui.sheet(activity, L("改这句"), body)
        d.window?.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE or android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        d.show()
        field.requestFocus()
    }

    /// The last fix decision said back for a few seconds, with 撤销, over the bottom of a screen
    /// (Android's own toast can't carry a button).
    class Toast(private val activity: Activity, private val ui: Ui, private val app: CicadaApp, private val above: Int = 24) {
        private var view: View? = null
        private var shownAt = 0L
        private val again = Runnable { refresh() }

        fun refresh() {
            val t = app.fixes.toastNow()
            val root = activity.findViewById<FrameLayout>(android.R.id.content) ?: return
            if (t == null) { view?.let { root.removeView(it) }; view = null; shownAt = 0; return }
            if (view != null && shownAt == t.at) return
            view?.let { root.removeView(it) }
            shownAt = t.at
            val pill = LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                background = ui.rounded(Palette.ink, 14)
                elevation = ui.dp(8).toFloat()
                setPadding(ui.dp(16), ui.dp(4), ui.dp(6), ui.dp(4))
                minimumHeight = ui.dp(52)
                addView(ui.text(t.text, 14f, Color.WHITE, lines = 2), ui.weight())
                if (app.fixes.canUndo) addView(ui.text(L("撤销"), 14f, Color.parseColor("#FFB59B"), bold = true).apply {
                    gravity = Gravity.CENTER; minHeight = ui.dp(44); setPadding(ui.dp(12), 0, ui.dp(12), 0)
                    ui.tappable(this, 10, dark = true) { app.background.execute { app.fixes.undo() } }
                })
                accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            }
            root.addView(pill, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM).apply { setMargins(ui.dp(16), 0, ui.dp(16), ui.dp(above)) })
            view = pill
            root.removeCallbacks(again)
            root.postDelayed(again, LiveFixes.TOAST_MS - (System.currentTimeMillis() - t.at) + 50)
        }
    }
}
