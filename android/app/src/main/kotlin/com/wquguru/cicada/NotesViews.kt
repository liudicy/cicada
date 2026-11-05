package com.wquguru.cicada

import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import cicada.Languages
import cicada.MeetingNotes
import cicada.NotesEngine
import cicada.Strings.L
import cicada.Strings.LF
import cicada.TranscriptLine
import java.time.Instant

/// What the live screens show, built the same way for 正在听 and the floating window.
object NotesViews {
    /// This meeting's lines while it runs (or until its last reply lands).
    fun currentLines(app: CicadaApp): List<TranscriptLine> {
        val listen = app.listen
        if (!listen.listening && listen.pending == 0) return emptyList()
        return listen.sessionId?.let { app.store.lines(it) } ?: emptyList()
    }

    /// No sound for 20 s from what the phone plays: most likely an app that can't be captured.
    fun silent(app: CicadaApp) = app.listen.let { it.listening && it.sourceKind == "playback" && it.heardSeconds > 20 && it.peak < 0.002 }

    /// Everything the live views show, so they are rebuilt only when it changes: a view replaced
    /// under a finger loses the tap.
    fun liveKey(app: CicadaApp): String {
        val listen = app.listen
        val line = listen.sessionId?.let { app.store.lines(it).lastOrNull() }
        return listOf(listen.listening, listen.sourceKind, listen.sessionId, listen.pending > 0, listen.problem, app.startProblem, silent(app), app.micSilenced,
                      line?.id, line?.src, line?.dst, app.notes.status, app.notes.notes.updatedAt, app.notes.notes.covered,
                      app.ending?.deadline).joinToString("|")
    }

    /// "正在听 · 03:12" / "面对面 · 03:12".
    fun status(app: CicadaApp): String {
        val head = if (app.listen.sourceKind == "mic") L("面对面") else L("正在听")
        return head + " · " + clock(app)
    }

    fun clock(app: CicadaApp): String = app.listen.sessionId?.let { app.store.get(it) }?.let { Languages.clock(it.durationSeconds) } ?: "00:00"

    /// "手机里的声音 · English → 简体中文".
    fun sourceLine(app: CicadaApp): String {
        val source = if (app.listen.sourceKind == "mic") L("面对面") else L("手机里的声音")
        val from = app.listen.spoken?.let { languageName(it) } ?: L("自动识别")
        return "$source · $from → ${languageName(app.settings.targetCode)}"
    }

    fun languageName(code: String) = Languages.targets.firstOrNull { it.code == code }?.name
        ?: Languages.sources.firstOrNull { it.code == code }?.name ?: code

    /// "刚刚更新" / "3 分钟前更新".
    fun updated(at: Instant?): String? {
        at ?: return null
        val minutes = (Instant.now().epochSecond - at.epochSecond) / 60
        return if (minutes < 1) L("刚刚更新") else LF("%@ 分钟前更新", minutes)
    }

    /// The problem banner of the live screens, or null. `onMic` offers 面对面 when nothing is heard.
    /// The meeting is about to end by itself (the Mac's MeetingEndingStrip): what's happening, the
    /// seconds left (tagged ENDING_DETAIL, updated in place each second so the buttons keep their
    /// touch), 继续记录 and 现在结束.
    fun endingStrip(ui: Ui, app: CicadaApp, compact: Boolean = false): View? {
        val p = app.ending ?: return null
        return ui.stack(if (compact) 8 else 12).apply {
            background = ui.rounded(Palette.accentPale, 16)
            setPadding(ui.dp(16), ui.dp(14), ui.dp(16), ui.dp(14))
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            addView(ui.stack(3, ui.text(app.endingTitle(p), if (compact) 15f else 16f, Palette.ink, bold = true),
                ui.text(app.endingDetail(p), 13f, Palette.secondary).apply { tag = ENDING_DETAIL }))
            addView(LinearLayout(ui.context).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(ui.button(L("继续记录"), "primary", height = 44) { app.keepRecording() }, ui.weight())
                addView(ui.button(L("现在结束"), "quiet", height = 44) { app.stopListening() }.apply { background = ui.rounded(Palette.card, 16) },
                        ui.weight().apply { leftMargin = ui.dp(10) })
            })
        }
    }

    const val ENDING_DETAIL = "endingDetail"
    const val ENDING_BAR = "endingBar"

    /// The subtitle bar has no buttons (as on the Mac): it says what will happen, and speaking
    /// keeps a silent meeting going.
    fun endingBarText(app: CicadaApp): String? = app.ending?.let { app.endingTitle(it) + " · " + LF("%lld 秒后结束", app.endingLeft(it)) }

    /// The countdown's seconds, without rebuilding the views around it.
    fun tickEnding(root: View?, app: CicadaApp) {
        val p = app.ending ?: return
        (root?.findViewWithTag<TextView>(ENDING_DETAIL))?.text = app.endingDetail(p)
        (root?.findViewWithTag<TextView>(ENDING_BAR))?.text = endingBarText(app)
    }

    fun banner(ui: Ui, app: CicadaApp, onMic: (() -> Unit)?): View? {
        val problem = app.listen.problem
        val (iconRes, text) = when {
            problem == L("连不上 Ling，检查网络") -> R.drawable.i_wifi_off to L("连不上 Ling，联网后继续出字幕")
            app.micSilenced && app.listen.listening -> R.drawable.i_mic to L("麦克风正被通话或其他 app 占用，用完后接着听")
            problem != null -> R.drawable.i_info to problem
            silent(app) -> R.drawable.i_speaker_off to L("20 秒没听到声音。通话和会议 app 的声音系统不让录")
            else -> return null
        }
        return LinearLayout(ui.context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = ui.rounded(Palette.card, 16)
            setPadding(ui.dp(14), ui.dp(10), ui.dp(6), ui.dp(10))
            minimumHeight = ui.dp(56)
            addView(ui.icon(R.drawable.i_info, 22, Palette.link).apply { setImageDrawable(ui.drawable(iconRes, Palette.link)) })
            addView(ui.text(text, 14f, Palette.ink), ui.weight().apply { leftMargin = ui.dp(12) })
            if (silent(app) && onMic != null) addView(ui.textButton(L("换成面对面"), onClick = onMic))
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
    }

    /// An import's progress: the bar and "26:40 / 42:15".
    fun progress(ui: Ui, file: FileSource): LinearLayout {
        val box = ui.stack(8)
        val frac = if (file.total > 0) (file.done / file.total).coerceIn(0.0, 1.0) else 0.0
        box.addView(LinearLayout(ui.context).apply {
            orientation = LinearLayout.HORIZONTAL
            background = ui.rounded(android.graphics.Color.parseColor("#E7E9EE"), 4)
            weightSum = 1f
            addView(View(ui.context).apply { background = ui.rounded(Palette.accent, 4) }, LinearLayout.LayoutParams(0, -1, frac.toFloat()))
            contentDescription = "${(frac * 100).toInt()}%"
        }, LinearLayout.LayoutParams(-1, ui.dp(8)))
        box.addView(ui.text("${Languages.clock(file.done)} / ${Languages.clock(file.total)}", 13f, Palette.secondary).apply { fontFeatureSettings = "tnum" })
        return box
    }

    /// Speaker colours (the iOS design's): the first voices blue and clay, then green and violet;
    /// 你 ink; 对方 / 未识别 grey. Each pair passes 4.5:1.
    private val voiceColors = listOf(0xFFDCE7F7.toInt() to 0xFF1F4E8C.toInt(), 0xFFF6E2D6.toInt() to 0xFF8A3A16.toInt(),
                                     0xFFDFF0E4.toInt() to 0xFF1E6B3A.toInt(), 0xFFEDE3F6.toInt() to 0xFF5B2E8A.toInt())
    fun voiceColor(number: Int?): Pair<Int, Int> = number?.let { voiceColors[(it - 1) % voiceColors.size] } ?: (0xFFE7E9EE.toInt() to 0xFF3F434C.toInt())

    /// A round initial for who said it.
    fun avatar(ui: Ui, line: TranscriptLine, numbers: Map<String, Int>, name: String, size: Int = 22) = ui.text(
        if (line.speaker == "me") L("你") else name.trim().firstOrNull()?.uppercase() ?: "?", 11f,
        if (line.speaker == "me") android.graphics.Color.WHITE else voiceColor(numbers[line.id]).second, bold = true).apply {
        gravity = Gravity.CENTER
        background = ui.rounded(if (line.speaker == "me") Palette.ink else voiceColor(numbers[line.id]).first, size / 2)
        layoutParams = LinearLayout.LayoutParams(ui.dp(size), ui.dp(size))
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /// One line as a white bubble: who and when, the original small and grey, the translation in
    /// ink. The newest is outlined in the accent while more may come.
    fun bubble(ui: Ui, line: TranscriptLine, numbers: Map<String, Int>, names: Map<Int, String>, newest: Boolean, listening: Boolean): LinearLayout {
        val who = cicada.SpeakerLabels.speakerName(line, numbers, names)
        val card = ui.stack(6)
        card.background = if (newest && listening) ui.rounded(Palette.card, 22, android.graphics.Color.parseColor("#F2C3B2"), 1.5) else ui.rounded(Palette.card, 22)
        card.setPadding(ui.dp(16), ui.dp(14), ui.dp(16), ui.dp(14))
        // An initial only for someone known (你, a numbered or named voice); 对方 has no face.
        val head = ui.text("$who · ${Languages.clock(line.t)}", 12f, Palette.secondary, lines = 1)
        card.addView(if (line.speaker == "me" || numbers[line.id] != null) ui.row(8, avatar(ui, line, numbers, who), head) else head)
        val translated = !line.dst.isNullOrEmpty() && line.dst != line.src
        if (translated) card.addView(ui.text(line.src, Ui.Type.ORIGINAL, Palette.secondary).apply { leading(1.45f) })
        card.addView(ui.text(line.dst?.takeIf { translated } ?: line.src, Ui.Type.TRANSLATION, Palette.ink).apply { leading(1.5f) })
        if (newest) card.accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        return card
    }

    /// The subtitle stream on 正在听: a bubble per line, the newest at the bottom.
    fun bubbles(ui: Ui, app: CicadaApp, count: Int): LinearLayout {
        val lines = currentLines(app)
        val box = ui.stack(12)
        if (lines.isEmpty()) return stream(ui, app, 0)
        val numbers = cicada.SpeakerLabels.numbers(lines)
        val names = app.listen.sessionId?.let { app.store.get(it) }?.let { cicada.SpeakerLabels.names(it) } ?: emptyMap()
        val shown = lines.takeLast(count)
        shown.forEachIndexed { i, l -> box.addView(bubble(ui, l, numbers, names, i == shown.lastIndex, app.listen.listening)) }
        if (app.listen.listening) box.addView(LinearLayout(ui.context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(ui.dp(8), 0, 0, 0)
            listOf(1f, 0.6f, 0.3f).forEach { a -> addView(ui.dot(Palette.accent, 6).apply { alpha = a }, LinearLayout.LayoutParams(ui.dp(6), ui.dp(6)).apply { rightMargin = ui.dp(5) }) }
            addView(ui.text(L("正在听下一句…"), 13f, Palette.secondary), LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(4) })
        })
        return box
    }

    /// The subtitle stream: earlier lines small, the newest as a large card at the bottom.
    fun stream(ui: Ui, app: CicadaApp, earlier: Int): LinearLayout {
        val lines = currentLines(app)
        val box = ui.stack(18)
        if (lines.isEmpty()) {
            box.addView(LinearLayout(ui.context).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                setPadding(0, ui.dp(64), 0, ui.dp(48))
                addView(ui.icon(R.drawable.i_waves, 36, Palette.outline))
                addView(ui.text(if (app.listen.pending > 0) L("正在听下一句…") else L("等有人说话…"), 15f, Palette.secondary), ui.lp(top = 14, width = -2))
            })
            return box
        }
        for (l in lines.dropLast(1).takeLast(earlier)) {
            val texts = ui.stack(2, ui.text(said(l), 13f, Palette.secondary))
            if (!l.dst.isNullOrEmpty() && l.dst != l.src) texts.addView(ui.text(l.dst!!, 16f, Palette.ink), ui.lp(top = 2))
            box.addView(LinearLayout(ui.context).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(ui.text(Languages.clock(l.t), 12f, Palette.secondary, bold = true), LinearLayout.LayoutParams(-2, -2).apply { topMargin = ui.dp(1); rightMargin = ui.dp(10) })
                addView(texts, ui.weight())
            })
        }
        box.addView(liveCard(ui, app, lines.last(), 23f))
        return box
    }

    /// The newest line as a card, with the "still listening" dots under it.
    /// The original as shown above its translation: mine is marked, so it's clear who said it.
    fun said(l: TranscriptLine) = if (l.speaker == "me") L("你") + " · " + l.src else l.src

    fun liveCard(ui: Ui, app: CicadaApp, line: TranscriptLine, big: Float, bg: Int = Palette.card, lines: Int = 0, dots: Boolean = true): LinearLayout {
        val card = ui.stack(0)
        card.background = ui.rounded(bg, 20)
        card.setPadding(ui.dp(18), ui.dp(16), ui.dp(18), ui.dp(16))
        card.accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        val translated = !line.dst.isNullOrEmpty() && line.dst != line.src
        if (!translated && line.speaker == "me") card.addView(ui.text(L("你"), 14f, Palette.secondary))
        if (translated) card.addView(ui.text(said(line), 14f, Palette.secondary, lines = if (lines > 0) lines - 1 else 0))
        card.addView(ui.text(line.dst ?: line.src, big, Palette.ink, bold = true, lines = lines).apply { leading(1.25f) }, ui.lp(top = if (translated || line.speaker == "me") 8 else 0))
        if (dots && app.listen.listening) card.addView(LinearLayout(ui.context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            listOf(1f, 0.6f, 0.3f).forEach { a -> addView(ui.dot(Palette.accent, 6).apply { alpha = a }, LinearLayout.LayoutParams(ui.dp(6), ui.dp(6)).apply { rightMargin = ui.dp(5) }) }
            addView(ui.text(L("正在听下一句…"), 13f, Palette.secondary), LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(4) })
        }, ui.lp(top = 12))
        return card
    }

    /// The notes: name and freshness, summary, topics, conclusions, to-dos. `compact` (the
    /// floating window) keeps the current topic only.
    fun notesBody(ui: Ui, notes: MeetingNotes, status: NotesEngine.State, listening: Boolean, compact: Boolean = false): LinearLayout {
        val body = ui.stack(0)
        if (notes.isEmpty) {
            val hint = when (status) {
                NotesEngine.State.NoKey -> L("需要 Ling key 才能听")
                NotesEngine.State.InvalidKey -> L("这个 Ling key 无效，看看有没有复制全，或换一个新的")
                NotesEngine.State.RateLimited -> L("请求过于频繁，稍后会自动重试。")
                NotesEngine.State.Updating -> L("正在整理纪要…")
                else -> if (listening) L("说几句后生成纪要，之后每 45 秒更新") else ""
            }
            if (hint.isNotEmpty()) body.addView(ui.text(hint, 14f, Palette.secondary))
            return body
        }
        if (!compact) {
            val head = LinearLayout(ui.context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(ui.heading(notes.title ?: L("纪要"), Ui.Type.TITLE).apply { maxLines = 2; leading(1.3f) }, ui.weight())
                val fresh = if (status == NotesEngine.State.Updating) L("正在整理纪要…") else updated(notes.updatedAt)
                if (fresh != null) addView(ui.text(fresh, 12f, Palette.secondary), LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(8) })
            }
            body.addView(head)
            if (notes.summary.isNotEmpty()) {
                body.addView(ui.notesLabel(L("总结")), ui.lp(top = 16))
                body.addView(ui.notesText(notes.summary), ui.lp(top = 6))
            }
        }
        val topics = if (compact) notes.topics.takeLast(1) else notes.topics
        topics.forEachIndexed { i, t ->
            body.addView(ui.row(10, ui.text(Languages.clock(t.start), 12f, Palette.link, bold = true).apply { fontFeatureSettings = "tnum" },
                                ui.text(t.title, if (compact) 15f else Ui.Type.BODY, Palette.ink, bold = true).apply { layoutParams = ui.weight() }),
                         ui.lp(top = if (compact && i == 0) 0 else 20))
            for (p in if (compact) t.points.takeLast(3) else t.points) body.addView(bullet(ui, p, if (compact) 14f else Ui.Type.BODY), ui.lp(top = 6))
        }
        if (!compact && notes.conclusions.isNotEmpty()) {
            body.addView(ui.notesLabel(L("结论")), ui.lp(top = 22))
            for (c in notes.conclusions) body.addView(bullet(ui, c.text, Ui.Type.BODY), ui.lp(top = 6))
        }
        if (!compact && notes.todos.isNotEmpty()) {
            body.addView(ui.notesLabel(L("待办")), ui.lp(top = 22))
            for (t in notes.todos) body.addView(todo(ui, t.text, t.owner), ui.lp(top = 8))
        }
        return body
    }

    fun bullet(ui: Ui, text: String, size: Float) = LinearLayout(ui.context).apply {
        orientation = LinearLayout.HORIZONTAL
        addView(ui.dot(Palette.tertiary, 5), LinearLayout.LayoutParams(ui.dp(5), ui.dp(5)).apply { topMargin = ui.dp((size * 0.72).toInt()); rightMargin = ui.dp(10); leftMargin = ui.dp(2) })
        addView(ui.text(text, size, Palette.ink).apply { leading(if (size >= Ui.Type.BODY) Ui.Type.LINE else 1.35f) }, ui.weight())
    }

    fun todo(ui: Ui, text: String, owner: String?) = LinearLayout(ui.context).apply {
        orientation = LinearLayout.HORIZONTAL
        addView(View(ui.context).apply { background = ui.rounded(0, 8, Palette.tertiary, 1.5) }, LinearLayout.LayoutParams(ui.dp(16), ui.dp(16)).apply { topMargin = ui.dp(5); rightMargin = ui.dp(10) })
        addView(ui.notesText(text + (owner?.let { " · $it" } ?: "")), ui.weight())
    }
}
