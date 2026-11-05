package com.wquguru.cicada

import android.app.Activity
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/// The palette (AGENTS.md, Views.swift › Palette): ground #F3F4F6, white surfaces, ink #15171C,
/// one accent #E8552B kept for "live" (the red dot, the timer, progress). Primary buttons are ink:
/// white on the accent is under 4.5:1.
object Palette {
    val ground = Color.parseColor("#F3F4F6")
    val card = Color.WHITE
    val ink = Color.parseColor("#15171C")
    val body = Color.parseColor("#3D414A")
    val secondary = Color.parseColor("#5A5F6B")
    val tertiary = Color.parseColor("#6B7080")
    val line = Color.parseColor("#E4E6EA")
    val divider = Color.parseColor("#EEF0F2")
    val outline = Color.parseColor("#C9CCD3")
    val selected = Color.parseColor("#E9EAED")
    val accent = Color.parseColor("#E8552B")
    val accentPale = Color.parseColor("#FDEBE4")
    val link = Color.parseColor("#B33B14")
    val scrim = Color.parseColor("#EB15171C")
    val onScrim = Color.parseColor("#D7D9DE")
}

/// Line height as a multiple of the font size, exactly (CSS's line-height). setLineSpacing's
/// multiplier scales the font's own line height instead, and Noto CJK's is already ~1.3: a
/// "1.6" there came out as ~2.1 and the notes read double-spaced (the design's type table).
fun TextView.leading(factor: Float) { lineHeight = Math.round(textSize * factor) }

/// View builders in code (no XML layouts), Material-sized: 48dp touch targets, 56dp rows and main
/// buttons, ripples on everything tappable.
class Ui(val context: Context) {
    fun dp(v: Number): Int = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), context.resources.displayMetrics).toInt()

    fun text(text: CharSequence, size: Float = 15f, color: Int = Palette.ink, bold: Boolean = false, lines: Int = 0, medium: Boolean = false) = TextView(context).apply {
        this.text = text
        setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
        setTextColor(color)
        typeface = when {
            bold -> Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            medium -> Typeface.create("sans-serif-medium", Typeface.NORMAL)
            else -> Typeface.DEFAULT
        }
        if (lines > 0) { maxLines = lines; ellipsize = TextUtils.TruncateAt.END }
        leading(1.4f)
    }

    fun title(text: String, size: Float = 28f) = text(text, size, Palette.ink, bold = true).apply { leading(1.25f); isAccessibilityHeading = true }
    fun heading(text: String, size: Float = 17f) = text(text, size, Palette.ink, bold = true).apply { isAccessibilityHeading = true }
    fun helper(text: String, color: Int = Palette.secondary) = text(text, 13f, color)
    /// A group's name over it: grey and regular (as on iOS), lined up with the rows' text.
    fun sectionLabel(text: String) = text(text, 13f, Palette.secondary).apply { setPadding(dp(16), dp(18), 0, dp(4)); isAccessibilityHeading = true }

    /// The notes' type scale, the same on every live and record screen (the design's B table):
    /// a 13 grey label over 16 ink body text at 1.6, a 20 bold title. Bold is kept for titles
    /// and names, so a page of notes doesn't read as all bold.
    object Type {
        const val TITLE = 20f
        const val BODY = 16f
        const val LINE = 1.6f
        const val LABEL = 13f
        const val ORIGINAL = 14f
        const val TRANSLATION = 17f
    }
    fun notesLabel(text: String) = text(text, Type.LABEL, Palette.secondary, medium = true).apply { isAccessibilityHeading = true }
    fun notesText(text: CharSequence, color: Int = Palette.ink) = text(text, Type.BODY, color).apply { leading(Type.LINE) }

    fun rounded(color: Int, radius: Number, stroke: Int? = null, strokeDp: Number = 1) = GradientDrawable().apply {
        setColor(color); cornerRadius = dp(radius).toFloat()
        if (stroke != null) setStroke(dp(strokeDp), stroke)
    }

    /// Touch feedback that keeps the shape: a ripple over `base`, clipped to it.
    fun ripple(base: Drawable?, radius: Number = 0, dark: Boolean = false): Drawable {
        val mask = GradientDrawable().apply { setColor(Color.WHITE); cornerRadius = dp(radius).toFloat() }
        val tint = if (dark) 0x33FFFFFF else 0x1F15171C
        return RippleDrawable(ColorStateList.valueOf(tint), base, mask)
    }

    fun <T : View> tappable(v: T, radius: Number, base: Drawable? = null, dark: Boolean = false, onClick: () -> Unit): T = v.apply {
        background = ripple(base, radius, dark)
        isClickable = true; isFocusable = true
        setOnClickListener { onClick() }
    }

    fun card(vararg children: View, padding: Int = 20, gap: Int = 14, radius: Int = 28) = stack(gap, *children).apply {
        background = rounded(Palette.card, radius)
        setPadding(dp(padding), dp(padding), dp(padding), dp(padding))
    }

    /// A white group of rows with thin dividers (lists, settings).
    fun group(rows: List<View>, radius: Int = 22) = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        background = rounded(Palette.card, radius)
        clipToOutline = true
        rows.forEachIndexed { i, r ->
            if (i > 0) addView(View(context).apply { setBackgroundColor(Palette.divider) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1).apply { leftMargin = dp(16) })
            addView(r, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
    }

    fun stack(gap: Int, vararg children: View) = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        children.forEachIndexed { i, c ->
            val own = c.layoutParams
            addView(c, LinearLayout.LayoutParams(own?.width ?: ViewGroup.LayoutParams.MATCH_PARENT, own?.height ?: ViewGroup.LayoutParams.WRAP_CONTENT)
                .apply { topMargin = if (i == 0) 0 else dp(gap) })
        }
    }

    fun row(gap: Int, vararg children: View) = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        children.forEachIndexed { i, c ->
            val own = c.layoutParams
            val p = if (own is LinearLayout.LayoutParams && own.weight > 0) LinearLayout.LayoutParams(own.width, own.height, own.weight)
                    else LinearLayout.LayoutParams(own?.width ?: ViewGroup.LayoutParams.WRAP_CONTENT, own?.height ?: ViewGroup.LayoutParams.WRAP_CONTENT)
            addView(c, p.apply { if (i > 0) leftMargin = dp(gap) })
        }
    }

    fun lp(top: Int = 0, width: Int = ViewGroup.LayoutParams.MATCH_PARENT, height: Int = ViewGroup.LayoutParams.WRAP_CONTENT) =
        LinearLayout.LayoutParams(width, height).apply { topMargin = dp(top) }

    fun weight(w: Float = 1f) = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, w)

    fun spacer() = View(context).apply { layoutParams = LinearLayout.LayoutParams(0, 1, 1f) }

    fun drawable(res: Int, color: Int): Drawable = context.getDrawable(res)!!.mutate().apply { setTint(color) }

    fun icon(res: Int, size: Int = 24, color: Int = Palette.body) = ImageView(context).apply {
        setImageDrawable(drawable(res, color))
        layoutParams = LinearLayout.LayoutParams(dp(size), dp(size))
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /// A 48dp round icon button with a label for TalkBack.
    fun iconButton(res: Int, label: String, color: Int = Palette.ink, size: Int = 24, dark: Boolean = false, onClick: () -> Unit) = FrameLayout(context).apply {
        contentDescription = label
        addView(ImageView(context).apply {
            setImageDrawable(drawable(res, color))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }, FrameLayout.LayoutParams(dp(size), dp(size), Gravity.CENTER))
        layoutParams = LinearLayout.LayoutParams(dp(48), dp(48))
        tappable(this, 24, dark = dark, onClick = onClick)
    }

    /// Main buttons, all pills: ink (primary; white on the accent is under 4.5:1), a quiet grey
    /// one, white (on the grey ground, lifted), or the pale accent (tonal).
    fun button(label: String, kind: String = "primary", iconRes: Int? = null, height: Int = 56, onClick: () -> Unit): LinearLayout {
        val (bg, fg) = when (kind) {
            "primary" -> Palette.ink to Color.WHITE
            "tonal" -> Palette.accentPale to Palette.link
            "white" -> Palette.card to Palette.ink
            else -> Palette.ground to Palette.ink
        }
        return LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            minimumHeight = dp(height)
            setPadding(dp(16), 0, dp(16), 0)
            if (iconRes != null) addView(icon(iconRes, 20, fg), LinearLayout.LayoutParams(dp(20), dp(20)).apply { rightMargin = dp(8) })
            addView(text(label, if (height >= 56) 17f else 15f, fg, bold = true, lines = 2).apply { gravity = Gravity.CENTER })
            setPadding(dp(16), dp(6), dp(16), dp(6))
            contentDescription = label
            tappable(this, height / 2, rounded(bg, height / 2), dark = kind == "primary", onClick = onClick)
            if (kind == "white") lift(this)
        }
    }

    /// A soft shadow under a white surface on the grey ground (the floating bars, round buttons).
    fun lift(v: View, level: Int = 3) {
        v.elevation = dp(level).toFloat()
        v.outlineAmbientShadowColor = 0x6615171C
        v.outlineSpotShadowColor = 0x6615171C
    }

    /// A round 48dp white button for the top of a screen (back, share, more), on the grey ground
    /// lifted, on a white page grey.
    fun roundButton(res: Int, label: String, onWhite: Boolean = false, onClick: () -> Unit) = FrameLayout(context).apply {
        contentDescription = label
        addView(ImageView(context).apply {
            setImageDrawable(drawable(res, Palette.ink))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }, FrameLayout.LayoutParams(dp(20), dp(20), Gravity.CENTER))
        layoutParams = LinearLayout.LayoutParams(dp(48), dp(48))
        tappable(this, 24, rounded(if (onWhite) Palette.ground else Palette.card, 24), onClick = onClick)
        if (!onWhite) lift(this, 1)
    }

    /// A text button (dialog-style): dark-accent text, 48dp tall.
    fun textButton(label: String, color: Int = Palette.link, onClick: () -> Unit) = text(label, 15f, color, bold = true).apply {
        gravity = Gravity.CENTER
        minHeight = dp(48)
        setPadding(dp(12), 0, dp(12), 0)
        tappable(this, 24, onClick = onClick)
    }

    fun dot(color: Int, size: Int = 8) = View(context).apply {
        background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(color); setSize(dp(size), dp(size)) }
        layoutParams = LinearLayout.LayoutParams(dp(size), dp(size))
    }

    /// A small rounded label (meta chips, "对方可见", "正在听").
    fun badge(label: String, fg: Int = Palette.link, bg: Int = Palette.accentPale, dot: Boolean = false, size: Float = 12f) = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = rounded(bg, 10)
        setPadding(dp(8), dp(3), dp(8), dp(3))
        if (dot) addView(this@Ui.dot(Palette.accent, 6), LinearLayout.LayoutParams(dp(6), dp(6)).apply { rightMargin = dp(5) })
        addView(text(label, size, fg, bold = true, lines = 1))
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
    }

    /// A square icon tile (leading icon in rows and descriptions).
    fun tile(res: Int, size: Int = 40, bg: Int = Palette.ground, fg: Int = Palette.body) = FrameLayout(context).apply {
        background = rounded(bg, size * 0.3)
        addView(ImageView(context).apply {
            setImageDrawable(drawable(res, fg))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }, FrameLayout.LayoutParams(dp(size * 0.52), dp(size * 0.52), Gravity.CENTER))
        layoutParams = LinearLayout.LayoutParams(dp(size), dp(size))
    }

    /// A list row: optional leading view, title and supporting text, optional trailing view, chevron.
    fun listRow(title: CharSequence, supporting: CharSequence? = null, leading: View? = null, trailing: View? = null, chevron: Boolean = true,
                titleView: View? = null, onClick: (() -> Unit)? = null) = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(56)
        setPadding(dp(16), dp(12), dp(if (chevron) 12 else 16), dp(12))
        if (leading != null) addView(leading, LinearLayout.LayoutParams(leading.layoutParams?.width ?: ViewGroup.LayoutParams.WRAP_CONTENT, leading.layoutParams?.height ?: ViewGroup.LayoutParams.WRAP_CONTENT).apply { rightMargin = dp(14) })
        val texts = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(titleView ?: text(title, 16f, Palette.ink, lines = 1))
            if (supporting != null) addView(text(supporting, 13f, Palette.secondary), lp(top = 3))
        }
        addView(texts, weight())
        if (trailing != null) addView(trailing, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { leftMargin = dp(10) })
        if (chevron) addView(icon(R.drawable.i_chevron_right, 20, Palette.tertiary), LinearLayout.LayoutParams(dp(20), dp(20)).apply { leftMargin = dp(6) })
        contentDescription = listOfNotNull(title, supporting).joinToString("，")
        if (onClick != null) tappable(this, 0, onClick = onClick)
    }

    /// Pill segments (iOS's segmented control, the design's B): a grey track, the chosen one a
    /// white pill (or ink, `ink`) inside it. `track` white for one on the grey ground.
    fun segmented(options: List<Pair<String, String>>, selected: String, ink: Boolean = false, track: Int = Palette.ground, onPick: (String) -> Unit) = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        background = rounded(track, 24)
        setPadding(dp(4), dp(4), dp(4), dp(4))
        options.forEach { (value, label) ->
            val on = value == selected
            val fg = if (on && ink) Color.WHITE else if (on) Palette.ink else Palette.secondary
            val seg = text(label, 15f, fg, bold = on, medium = !on, lines = 1).apply {
                gravity = Gravity.CENTER
                minHeight = dp(40)
                setPadding(dp(8), 0, dp(8), 0)
                contentDescription = label
                accessibilityDelegate = object : View.AccessibilityDelegate() {
                    override fun onInitializeAccessibilityNodeInfo(host: View, info: android.view.accessibility.AccessibilityNodeInfo) {
                        super.onInitializeAccessibilityNodeInfo(host, info)
                        info.isCheckable = true; info.isChecked = on; info.className = "android.widget.RadioButton"
                    }
                }
                tappable(this, 20, if (on) rounded(if (ink) Palette.ink else Palette.card, 20) else null, dark = on && ink) { if (!on) onPick(value) }
                if (on && !ink) lift(this, 1)
            }
            addView(seg, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
        clipToPadding = false; clipChildren = false
    }

    /// A filter chip: a white pill, or ink when on.
    fun chip(label: String, on: Boolean, onClick: () -> Unit) = text(label, 14f, if (on) Color.WHITE else Palette.ink, bold = on, medium = !on, lines = 1).apply {
        gravity = Gravity.CENTER
        minHeight = dp(40)
        setPadding(dp(16), 0, dp(16), 0)
        isSelected = on
        tappable(this, 20, rounded(if (on) Palette.ink else Palette.card, 20), dark = on, onClick = onClick)
    }

    /// Two or three views of one thing (纪要 / 字幕): pill segments, by index.
    fun tabs(labels: List<String>, selected: Int, ink: Boolean = false, track: Int = Palette.ground, onPick: (Int) -> Unit) =
        segmented(labels.mapIndexed { i, l -> "$i" to l }, "$selected", ink, track) { onPick(it.toInt()) }

    /// The app icon, rounded like the launcher shows it.
    fun logo(size: Int = 64) = ImageView(context).apply {
        setImageDrawable(context.getDrawable(R.mipmap.ic_launcher))
        layoutParams = LinearLayout.LayoutParams(dp(size), dp(size))
        background = rounded(Palette.card, size * 0.23)
        clipToOutline = true
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /// A password-style field whose keyboard "done" key does `done`.
    fun keyField(done: () -> Unit) = android.widget.EditText(context).apply {
        hint = "sk-…"; setSingleLine()
        inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
        imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_DONE
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        background = null
        setPadding(0, dp(8), 0, dp(8))
        setOnEditorActionListener { _, action, _ -> if (action == android.view.inputmethod.EditorInfo.IME_ACTION_DONE) { done(); true } else false }
    }

    fun divider() = View(context).apply {
        setBackgroundColor(Palette.line)
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(1))
    }

    /// An Activity's frame (the design's B, after the iOS app): a large 34 title on the top-level
    /// screens; round back / action buttons on the others, the title (if any) large under them;
    /// a body that scrolls; and an optional bar floating over the bottom of it (the main buttons,
    /// or the 会议记录 / 设置 navigation), the content scrolling under it.
    fun screen(activity: Activity, title: String?, back: Boolean, ground: Int, actions: List<View> = emptyList(),
               bottom: View? = null, scroll: Boolean = true, body: View, center: View? = null): FrameLayout {
        activity.window.statusBarColor = ground
        activity.window.navigationBarColor = ground
        val root = FrameLayout(context).apply {
            setBackgroundColor(ground)
            fitsSystemWindows = true
        }
        val column = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        val side = sideInset()
        val bar = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(64)
            setPadding(dp(16) + side, dp(8), dp(16) + side, 0)
            if (back) addView(roundButton(R.drawable.i_back, cicada.Strings.L("返回"), onWhite = ground == Palette.card) { activity.finish() })
            when {
                center != null -> addView(FrameLayout(context).apply { addView(center, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER)) }, weight())
                title != null && !back -> addView(text(title, 34f, Palette.ink, bold = true, lines = 1).apply { isAccessibilityHeading = true; setPadding(dp(4), 0, 0, 0) }, weight())
                else -> addView(spacer())
            }
            actions.forEachIndexed { i, a -> addView(a, LinearLayout.LayoutParams(a.layoutParams?.width ?: -2, a.layoutParams?.height ?: -2).apply { if (i > 0) leftMargin = dp(10) }) }
            if (back && center != null && actions.isEmpty()) addView(View(context), LinearLayout.LayoutParams(dp(48), dp(48)))
        }
        column.addView(bar)
        if (back && title != null) column.addView(text(title, 30f, Palette.ink, bold = true, lines = 2).apply {
            isAccessibilityHeading = true; setPadding(dp(20) + side, dp(12), dp(20) + side, dp(4))
        })
        val inner = readable(body)
        val content = if (scroll) ScrollView(context).apply { isVerticalScrollBarEnabled = false; addView(inner); clipToPadding = false } else inner
        // What scrolls ends above the floating bar, but passes under it.
        if (bottom != null) {
            content.setPadding(content.paddingLeft, content.paddingTop, content.paddingRight, content.paddingBottom + dp(96))
            (content as? ViewGroup)?.clipToPadding = false
        }
        column.addView(content, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(column, FrameLayout.LayoutParams(-1, -1))
        if (bottom != null) {
            if (side > 0) bottom.setPadding(bottom.paddingLeft + side, bottom.paddingTop, bottom.paddingRight + side, bottom.paddingBottom)
            root.addView(bottom, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM))
        }
        return root
    }

    /// The top-level screens' floating navigation (iOS's tab bar, solid white instead of glass):
    /// 会议记录 and 设置 in one pill, search in a round one beside it.
    fun nav(activity: Activity, current: String): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(16), dp(28), dp(16), dp(16))
        background = fade()
        val pill = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            background = rounded(Palette.card, 32)
            setPadding(dp(6), dp(6), dp(6), dp(6))
            lift(this, 4)
            listOf(Triple("records", R.drawable.i_list, cicada.Strings.L("会议记录")), Triple("settings", R.drawable.i_settings, cicada.Strings.L("设置"))).forEach { (id, res, label) ->
                val on = id == current
                val item = LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER
                    minimumHeight = dp(52)
                    contentDescription = label
                    isSelected = on
                    addView(icon(res, 22, if (on) Palette.ink else Palette.secondary), LinearLayout.LayoutParams(dp(22), dp(22)))
                    addView(text(label, 11f, if (on) Palette.ink else Palette.secondary, bold = on, lines = 1), LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(2) })
                    tappable(this, 26, if (on) rounded(Palette.ground, 26) else null) {
                        if (on) return@tappable
                        val target = if (id == "settings") SettingsActivity::class.java else MainActivity::class.java
                        activity.startActivity(android.content.Intent(activity, target).addFlags(android.content.Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
                        @Suppress("DEPRECATION") activity.overridePendingTransition(0, 0)
                    }
                }
                addView(item, LinearLayout.LayoutParams(0, -2, 1f).apply { if (id != "records") leftMargin = dp(4) })
            }
        }
        addView(pill, LinearLayout.LayoutParams(0, dp(64), 1f))
        val search = FrameLayout(context).apply {
            contentDescription = cicada.Strings.L("搜索会议、人名、词语")
            addView(icon(R.drawable.i_search, 22, Palette.ink), FrameLayout.LayoutParams(dp(22), dp(22), Gravity.CENTER))
            tappable(this, 32, rounded(Palette.card, 32)) { activity.startActivity(android.content.Intent(activity, RecordsActivity::class.java)) }
            lift(this, 4)
        }
        addView(search, LinearLayout.LayoutParams(dp(64), dp(64)).apply { leftMargin = dp(12) })
    }

    /// The ground fading in under a floating bar, so text scrolling under it doesn't fight it.
    fun fade(color: Int = Palette.ground): Drawable =
        GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(color and 0x00FFFFFF, color, color)).apply { setGradientCenter(0.5f, 0.45f) }

    /// On a tablet or a wide window, the gutter that keeps content at a readable 640dp.
    fun sideInset(): Int {
        val w = context.resources.configuration.screenWidthDp
        return if (w > 700) dp((w - 640) / 2) else 0
    }

    private fun readable(body: View): View {
        val side = sideInset()
        if (side == 0) return body
        return FrameLayout(context).apply {
            setPadding(side, 0, side, 0)
            addView(body, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, if (body is ScrollView) ViewGroup.LayoutParams.MATCH_PARENT else ViewGroup.LayoutParams.WRAP_CONTENT))
        }
    }

    /// The floating bottom area: one or two pill buttons side by side over the fading ground.
    fun bottomBar(vararg buttons: View, ground: Int = Palette.ground) = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        background = fade(ground)
        clipToPadding = false; clipChildren = false
        setPadding(dp(16), dp(28), dp(16), dp(16))
        buttons.forEachIndexed { i, b -> addView(b, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { if (i > 0) leftMargin = dp(12) }) }
    }

    // MARK: Bottom sheets (no Material library: a Dialog at the bottom, our own shape)

    /// A sheet that rises from the bottom (in place of AlertDialog and PopupMenu): a grab bar,
    /// an optional title, then `content`.
    fun sheet(activity: Activity, title: String?, content: View): android.app.Dialog {
        val d = android.app.Dialog(activity)
        d.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE)
        val box = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(Palette.card, 32)
            setPadding(dp(16), dp(10), dp(16), dp(20))
            addView(View(activity).apply { background = rounded(Color.parseColor("#D5D7DC"), 3) }, LinearLayout.LayoutParams(dp(36), dp(5)).apply { gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = dp(12) })
            if (title != null) addView(text(title, 17f, Palette.ink, bold = true).apply { gravity = Gravity.CENTER; isAccessibilityHeading = true; setPadding(dp(8), 0, dp(8), dp(10)) })
            addView(content)
        }
        val frame = FrameLayout(activity).apply { setPadding(dp(8), 0, dp(8), dp(8)); addView(box) }
        d.setContentView(frame)
        d.window?.apply {
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            setGravity(Gravity.BOTTOM)
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            setDimAmount(0.38f)
            val w = context.resources.configuration.screenWidthDp
            if (w > 600) setLayout(dp(560), ViewGroup.LayoutParams.WRAP_CONTENT)
        }
        return d
    }

    /// One action in a sheet: a round grey icon, the label (and a grey line), red when it destroys.
    fun sheetAction(res: Int, label: String, helper: String? = null, destructive: Boolean = false, onClick: () -> Unit) = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(56)
        setPadding(dp(8), dp(6), dp(8), dp(6))
        val red = Color.parseColor("#B3261E")
        addView(FrameLayout(context).apply {
            background = rounded(if (destructive) Color.parseColor("#FBEAE8") else Palette.ground, 20)
            addView(icon(res, 20, if (destructive) red else Palette.ink), FrameLayout.LayoutParams(dp(20), dp(20), Gravity.CENTER))
        }, LinearLayout.LayoutParams(dp(40), dp(40)))
        addView(stack(2, text(label, 16f, if (destructive) red else Palette.ink, lines = 1)).apply { if (helper != null) addView(text(helper, 13f, Palette.secondary)) },
                weight().apply { leftMargin = dp(14) })
        contentDescription = listOfNotNull(label, helper).joinToString("，")
        tappable(this, 16, onClick = onClick)
    }

    /// Choose one of `options` in a sheet (replaces the single-choice AlertDialog).
    fun choose(activity: Activity, title: String, options: List<Pair<String, String>>, selected: String, onPick: (String) -> Unit) {
        val list = stack(0)
        lateinit var d: android.app.Dialog
        options.forEach { (value, label) ->
            val on = value == selected
            list.addView(LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                minimumHeight = dp(52)
                setPadding(dp(16), 0, dp(12), 0)
                addView(text(label, 16f, Palette.ink, bold = on, lines = 1), weight())
                if (on) addView(icon(R.drawable.i_check, 20, Palette.ink), LinearLayout.LayoutParams(dp(20), dp(20)))
                contentDescription = label
                isSelected = on
                tappable(this, 16, if (on) rounded(Palette.ground, 16) else null) { d.dismiss(); if (!on) onPick(value) }
            })
        }
        val body: View = if (options.size > 8) ScrollView(context).apply { addView(list); layoutParams = LinearLayout.LayoutParams(-1, dp(52 * 8)) } else list
        d = sheet(activity, title, body)
        d.show()
    }

    /// Asks before something happens: a message and two pills, the safe one first-reached.
    fun confirm(activity: Activity, title: String, message: String?, ok: String, cancel: String = cicada.Strings.L("取消"),
                destructive: Boolean = false, onOk: () -> Unit) {
        lateinit var d: android.app.Dialog
        val body = stack(0)
        if (message != null) body.addView(text(message, 15f, Palette.secondary).apply { gravity = Gravity.CENTER; setPadding(dp(12), 0, dp(12), 0) })
        val okButton = button(ok, "primary") { d.dismiss(); onOk() }
        if (destructive) okButton.background = ripple(rounded(Color.parseColor("#B3261E"), 28), 28, dark = true)
        body.addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(button(cancel, "quiet") { d.dismiss() }, weight())
            addView(okButton, weight().apply { leftMargin = dp(10) })
        }, lp(top = 18))
        d = sheet(activity, title, body)
        d.show()
    }

    /// A text to type (rename): the field, 取消 and 保存. The keyboard comes up with the sheet.
    fun input(activity: Activity, title: String, initial: String, helper: String? = null, hint: String? = null, onSave: (String) -> Unit) {
        lateinit var d: android.app.Dialog
        val box = android.widget.EditText(activity).apply {
            setText(initial); setSelectAllOnFocus(true); setSingleLine()
            this.hint = hint
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            background = rounded(Palette.ground, 16)
            setPadding(dp(16), 0, dp(16), 0)
            minHeight = dp(52)
            imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_DONE
            setOnEditorActionListener { _, a, _ -> if (a == android.view.inputmethod.EditorInfo.IME_ACTION_DONE) { d.dismiss(); onSave(text.toString().trim()); true } else false }
        }
        val body = stack(0, box)
        if (helper != null) body.addView(helper(helper).apply { setPadding(dp(4), 0, dp(4), 0) }, lp(top = 8))
        body.addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(button(cicada.Strings.L("取消"), "quiet") { d.dismiss() }, weight())
            addView(button(cicada.Strings.L("保存"), "primary") { d.dismiss(); onSave(box.text.toString().trim()) }, weight().apply { leftMargin = dp(10) })
        }, lp(top = 16))
        d = sheet(activity, title, body)
        d.window?.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE or android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        d.show()
        box.requestFocus()
    }
}
