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
                      line?.id, line?.shown, line?.dst, app.notes.status, app.notes.notes.updatedAt, app.notes.notes.covered,
                      app.ending?.deadline, app.ling.blocking, listen.problemKind, app.ling.provider.id, customOnlyUntranslated(app),
                      // 改正听错的词: the newest line's fixes, the card and the 撤销 message.
                      line?.fixes, listen.sessionId?.let { app.fixes.asking(it)?.fix }, app.fixes.toastNow()?.at, app.settings.showInCapture).joinToString("|")
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
        val kind = app.listen.problemKind
        // A key, the credit or a model: before the hearing's own words ("Ling key 无效"), which say less.
        val blocking = app.ling.blocking
        val micTaken = app.micSilenced && app.listen.listening
        // The service's trouble is a status line; the microphone taken or nothing heard is not.
        when {
            // Hearing goes through the service too: the subtitles wait with the notes. The network or
            // the proxy, not the notes: it picks up by itself, or 改用 Ling when that key is saved.
            kind == "network" -> return statusLine(ui, Tone.Waiting, LF("字幕和纪要等 %@ 恢复 · 连上后自动继续", serviceLabel(app)),
                                                    if (app.canSwitchToLing) L("改用 Ling") to { app.switchToLing() } else null)
            micTaken -> {}
            blocking != null -> return statusLine(ui, Tone.NeedsYou, blocking, openSettings(ui, onMic))
            problem != null -> return statusLine(ui, when (kind) { "busy" -> Tone.Waiting; "key" -> Tone.NeedsYou; else -> Tone.Info },
                                                 problem, openSettings(ui, onMic).takeIf { kind == "key" })
            // 语音和文字只发给你的服务: heard, but the user's service didn't translate and Google isn't
            // asked. It picks up by itself; no 改用 Ling, which would send the meeting elsewhere.
            customOnlyUntranslated(app) -> return statusLine(ui, Tone.Waiting, LF("译文等 %@ 恢复 · 字幕先显示原文", serviceLabel(app)))
            !silent(app) -> return null
        }
        val (iconRes, text) = if (micTaken) R.drawable.i_mic to L("麦克风正被通话或其他 app 占用，用完后接着听")
                              else R.drawable.i_speaker_off to L("20 秒没听到声音。通话和会议 app 的声音系统不让录")
        return LinearLayout(ui.context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = ui.rounded(Palette.card, 16)
            setPadding(ui.dp(14), ui.dp(10), ui.dp(6), ui.dp(10))
            minimumHeight = ui.dp(56)
            addView(ui.icon(R.drawable.i_info, 22, Palette.link).apply { setImageDrawable(ui.drawable(iconRes, Palette.link)) })
            addView(ui.text(text, 14f, Palette.ink), ui.weight().apply { leftMargin = ui.dp(12) })
            if (!micTaken && onMic != null) addView(ui.textButton(L("换成面对面"), onClick = onMic))
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
    }

    /// 打开设置 › AI 服务, on Cicada's own screens only (`onMic` set): not from the floating window.
    private fun openSettings(ui: Ui, onMic: (() -> Unit)?): Pair<String, () -> Unit>? = if (onMic == null) null
        else L("打开设置") to { ui.context.startActivity(android.content.Intent(ui.context, AiServiceActivity::class.java)) }

    /// How a status line reads at a glance, by its dot alone (a passing wait shouldn't look like a
    /// fault): Waiting comes back by itself, NeedsYou is the user's to fix, Info is just so you know.
    enum class Tone { Waiting, NeedsYou, Info }

    /// A service in trouble, said the same way wherever it shows (the Mac's StatusLine): a dot,
    /// "what waits for what · what still works", and at most one action. The text is child 1:
    /// the floating window's subtitle bar takes it from there.
    fun statusLine(ui: Ui, tone: Tone, text: String, action: Pair<String, () -> Unit>? = null): LinearLayout = LinearLayout(ui.context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = ui.rounded(FILL, 10)
        setPadding(ui.dp(12), ui.dp(7), ui.dp(if (action != null) 4 else 12), ui.dp(7))
        minimumHeight = ui.dp(36)
        addView(ui.dot(when (tone) { Tone.Waiting -> WAITING; Tone.NeedsYou -> Palette.link; Tone.Info -> Palette.tertiary }, 6))
        addView(ui.text(text, 12f, Palette.secondary).apply { leading(1.4f) }, ui.weight().apply { leftMargin = ui.dp(8) })
        if (action != null) addView(ui.tappable(ui.text(action.first, 12f, Palette.ink, bold = true, lines = 1).apply {
            gravity = Gravity.CENTER
            minHeight = ui.dp(36)
            setPadding(ui.dp(8), 0, ui.dp(8), 0)
        }, 8, onClick = action.second), LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(4) })
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
    }

    /// #C98A00, the Mac's waiting dot: AiCheckViews.warn is too dark to tell from the text at 6 dp.
    private val WAITING = android.graphics.Color.parseColor("#C98A00")

    /// Finished sentences going untranslated with 语音和文字只发给你的服务 in effect (the Mac's googleOff banner).
    private fun customOnlyUntranslated(app: CicadaApp) =
        app.listen.listening && app.translator.googleOff && app.translator.sentencesUntranslated

    /// Where this meeting's notes stop: the time of the last line they cover.
    private fun serviceLabel(app: CicadaApp): String = app.ling.serviceLabel

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
    fun bubble(ui: Ui, line: TranscriptLine, numbers: Map<String, Int>, names: Map<Int, String>, newest: Boolean, listening: Boolean,
               onRevert: ((String, cicada.LineFix) -> Unit)? = null): LinearLayout {
        val who = cicada.SpeakerLabels.speakerName(line, numbers, names)
        val card = ui.stack(6)
        card.background = if (newest && listening) ui.rounded(Palette.card, 22, android.graphics.Color.parseColor("#F2C3B2"), 1.5) else ui.rounded(Palette.card, 22)
        card.setPadding(ui.dp(16), ui.dp(14), ui.dp(16), ui.dp(14))
        // An initial only for someone known (你, a numbered or named voice); 对方 has no face.
        val head = ui.text("$who · ${Languages.clock(line.t)}", 12f, Palette.secondary, lines = 1)
        card.addView(if (line.speaker == "me" || numbers[line.id] != null) ui.row(8, avatar(ui, line, numbers, who), head) else head)
        val translated = !line.dst.isNullOrEmpty() && line.dst != line.shown
        if (translated) card.addView(ui.text(FixViews.text(ui, line), Ui.Type.ORIGINAL, Palette.secondary).apply { leading(1.45f) })
        card.addView(ui.text(line.dst?.takeIf { translated } ?: FixViews.text(ui, line), Ui.Type.TRANSLATION, Palette.ink).apply { leading(1.5f) })
        // The line being said shows its fixed words open (the Mac's notes window does too): nothing to hover with.
        if (onRevert != null) FixViews.fixedWords(ui, line.id, line.fixes ?: emptyList(), onRevert)?.let { card.addView(it, ui.lp(top = 4)) }
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
        val id = app.listen.sessionId
        shown.forEachIndexed { i, l ->
            val revert: ((String, cicada.LineFix) -> Unit)? = if (i == shown.lastIndex && id != null) { lineId, f -> app.fixes.revert(f, lineId, id) } else null
            box.addView(bubble(ui, l, numbers, names, i == shown.lastIndex, app.listen.listening, revert))
        }
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
            if (!l.dst.isNullOrEmpty() && l.dst != l.shown) texts.addView(ui.text(l.dst!!, 16f, Palette.ink), ui.lp(top = 2))
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
    fun said(l: TranscriptLine) = if (l.speaker == "me") L("你 · 同传") + " · " + l.shown else l.shown

    fun liveCard(ui: Ui, app: CicadaApp, line: TranscriptLine, big: Float, bg: Int = Palette.card, lines: Int = 0, dots: Boolean = true): LinearLayout {
        val card = ui.stack(0)
        card.background = ui.rounded(bg, 20)
        card.setPadding(ui.dp(18), ui.dp(16), ui.dp(18), ui.dp(16))
        card.accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        val translated = !line.dst.isNullOrEmpty() && line.dst != line.shown
        if (!translated && line.speaker == "me") card.addView(ui.text(L("你 · 同传"), 14f, Palette.secondary))
        if (translated) card.addView(ui.text(if (line.speaker == "me") said(line) else FixViews.text(ui, line), 14f, Palette.secondary, lines = if (lines > 0) lines - 1 else 0))
        card.addView(ui.text(line.dst ?: FixViews.text(ui, line), big, Palette.ink, bold = true, lines = lines).apply { leading(1.25f) }, ui.lp(top = if (translated || line.speaker == "me") 8 else 0))
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
    /// `heard`: this meeting's lines so far, for the listening placeholder.
    fun notesBody(ui: Ui, notes: MeetingNotes, status: NotesEngine.State, listening: Boolean, compact: Boolean = false, heard: Int = 0): LinearLayout {
        val body = ui.stack(0)
        notesTrouble(ui, notes, status, listening, actions = !compact)?.let { body.addView(it, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = ui.dp(12) }) }
        // Listening and no request out yet (the first waits for a few lines or 20 s): the notes'
        // own shape, kept after the first line is heard (the Mac's notesPane).
        if (notes.isEmpty && listening && (status == NotesEngine.State.Idle || status == NotesEngine.State.Failed)) {
            body.addView(listeningPlaceholder(ui, heard, compact))
            return body
        }
        // The first version on its way (the Mac's NotesGeneratingView): the same shape, a spinner
        // and how many lines it was written from, not a bare 正在整理纪要… for the 10–20 s it takes.
        if (notes.isEmpty && listening && heard > 0 && status == NotesEngine.State.Updating) {
            body.addView(listeningPlaceholder(ui, heard, compact, generating = true))
            return body
        }
        if (notes.isEmpty) {
            val hint = when (status) {
                NotesEngine.State.NoKey -> CicadaApp.shared.noKeyText()
                NotesEngine.State.Updating -> L("正在整理纪要…")
                else -> ""
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
            for (t in notes.todos) body.addView(todo(ui, t.withOwner), ui.lp(top = 8))
        }
        return body
    }

    /// What went wrong with the notes' own request, as a status line (the Mac's notes banner), or
    /// null. What the live banner already says (the service unreachable, busy for the hearing too,
    /// a key it can't use) isn't said twice. `actions`: 换 key opens the settings, so not from the
    /// floating window.
    private fun notesTrouble(ui: Ui, notes: MeetingNotes, status: NotesEngine.State, listening: Boolean, actions: Boolean): View? {
        val app = CicadaApp.shared
        val shown = app.listen.problemKind.takeIf { listening }
        return when {
            status == NotesEngine.State.InvalidKey && !(listening && app.ling.blocking != null) -> {
                val stopped = currentLines(app).getOrNull(notes.covered - 1)?.t.takeIf { !notes.isEmpty }
                statusLine(ui, Tone.NeedsYou, if (stopped != null) LF("key 失效了 · 纪要停在 %@", Languages.clock(stopped)) else L("key 失效了 · 纪要等新的 key"),
                           if (actions) L("换 key") to { ui.context.startActivity(android.content.Intent(ui.context, AiServiceActivity::class.java)) } else null)
            }
            // A busy notes request is its own: the hearing goes on unless it is busy too (then the banner says so).
            status == NotesEngine.State.RateLimited && (listening || notes.isEmpty) && shown != "busy" ->
                statusLine(ui, Tone.Waiting, LF("%@ 很忙 · 纪要稍后补上，字幕照常", serviceLabel(app)))
            // Nothing reached: the banner's 字幕和纪要等 … 恢复 covers this round too.
            status == NotesEngine.State.Failed && listening && shown != "network" ->
                statusLine(ui, Tone.Info, L("这轮纪要没写好 · 下轮自动补上"))
            else -> null
        }
    }

    /// The Mac's NotesListeningView: a quiet status row, then the notes' shape waiting to be
    /// filled and what they will hold. `compact` (the floating window) keeps the status row only.
    /// `generating`: the first request is out: a spinner and 正在生成纪要… instead of the sound bars,
    /// and no list of what the notes will hold (the Mac's NotesGeneratingView).
    fun listeningPlaceholder(ui: Ui, heard: Int, compact: Boolean, generating: Boolean = false): LinearLayout {
        val box = ui.stack(0)
        box.addView(LinearLayout(ui.context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = ui.rounded(0xB3FDEBE4.toInt(), 12)  // accentPale at 70%, as on the Mac
            setPadding(ui.dp(14), ui.dp(12), ui.dp(14), ui.dp(12))
            if (generating) {
                addView(android.widget.ProgressBar(ui.context).apply {
                    isIndeterminate = true
                    indeterminateTintList = android.content.res.ColorStateList.valueOf(Palette.accent)
                }, LinearLayout.LayoutParams(ui.dp(20), ui.dp(20)))
                addView(ui.text(L("正在生成纪要…"), 13f, Palette.ink, bold = true), ui.weight().apply { leftMargin = ui.dp(12) })
            } else {
                addView(SoundBars(ui.context), LinearLayout.LayoutParams(ui.dp(21), ui.dp(22)))
                addView(ui.text(L("有人开口后，约半分钟出第一版"), 13f, Palette.ink), ui.weight().apply { leftMargin = ui.dp(12) })
            }
            if (heard > 0) addView(ui.text(LF("已听到 %lld 句", heard), 12f, Palette.tertiary, lines = 1).apply { fontFeatureSettings = "tnum" },
                                   LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(12) })
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        })
        if (compact) return box
        fun heading(text: String) = ui.text(text, 15f, PLACEHOLDER, bold = true).apply { importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }
        box.addView(heading(L("总结")), ui.lp(top = 22))
        listOf(0.94f, 0.8f, 0.56f).forEach { box.addView(SkeletonBar(ui.context, it), ui.lp(top = 10, height = ui.dp(10))) }
        box.addView(heading(L("议题")), ui.lp(top = 22))
        box.addView(topicSlot(ui, "00:00", listOf(0.52f, 0.88f, 0.7f)), ui.lp(top = 12))
        box.addView(topicSlot(ui, "--:--", listOf(0.4f, 0.76f)).apply { alpha = 0.6f }, ui.lp(top = 12))
        if (generating) return box
        // Wraps: the English chips don't fit one line on a phone.
        box.addView(FlowRow(ui.context, ui.dp(6)).apply {
            addView(ui.text(L("会整理出"), 12f, Palette.tertiary).apply { setPadding(0, ui.dp(4), 0, ui.dp(4)) })
            for (t in listOf(L("结论"), L("待办"), L("人名和术语"), L("鱼骨图"))) addView(ui.text(t, 12f, Palette.secondary, lines = 1).apply {
                background = ui.rounded(FILL, 100)
                setPadding(ui.dp(10), ui.dp(4), ui.dp(10), ui.dp(4))
            })
        }, ui.lp(top = 26))
        return box
    }

    private fun topicSlot(ui: Ui, time: String, fractions: List<Float>) = LinearLayout(ui.context).apply {
        orientation = LinearLayout.HORIZONTAL
        background = android.graphics.drawable.GradientDrawable().apply {
            cornerRadius = ui.dp(12).toFloat()
            setStroke(ui.dp(1.5f), Palette.line, ui.dp(5).toFloat(), ui.dp(4).toFloat())
        }
        setPadding(ui.dp(14), ui.dp(14), ui.dp(14), ui.dp(14))
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        addView(ui.text(time, 12f, PLACEHOLDER, lines = 1).apply { fontFeatureSettings = "tnum" })
        addView(ui.stack(0).apply {
            fractions.forEachIndexed { i, f -> addView(SkeletonBar(ui.context, f), ui.lp(top = if (i == 0) 2 else 8, height = ui.dp(if (i == 0) 11 else 8))) }
        }, ui.weight().apply { leftMargin = ui.dp(12) })
    }

    /// The Mac's Palette.placeholder and Palette.fill.
    private val PLACEHOLDER = android.graphics.Color.parseColor("#B8BDC6")
    private val FILL = android.graphics.Color.parseColor("#F2F3F5")

    /// 0..1 through a repeating cycle (the Mac's phase()); with animations off, one still frame
    /// (bars at mixed heights).
    fun phase(period: Double, delay: Double = 0.0): Double {
        val now = if (android.animation.ValueAnimator.areAnimatorsEnabled()) android.os.SystemClock.uptimeMillis() / 1000.0 else 0.4
        val t = now - delay
        return ((t % period) + period) % period / period
    }

    /// Four small orange bars rising and falling: "listening". Redraws itself only while drawn,
    /// so it stops once detached or off screen.
    class SoundBars(context: android.content.Context) : View(context) {
        private val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { color = Palette.accent }
        private val rect = android.graphics.RectF()
        init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }
        override fun onDraw(canvas: android.graphics.Canvas) {
            val d = resources.displayMetrics.density
            val w = 3 * d; val gap = 3 * d; val h = height.toFloat()
            for (i in 0 until 4) {
                val p = phase(1.1, i * 0.15)
                val bar = h * (0.3f + 0.7f * (0.5f - 0.5f * Math.cos(p * 2 * Math.PI).toFloat()))
                val x = i * (w + gap)
                rect.set(x, (h - bar) / 2, x + w, (h + bar) / 2)
                canvas.drawRoundRect(rect, w / 2, w / 2, paint)
            }
            if (android.animation.ValueAnimator.areAnimatorsEnabled()) postInvalidateDelayed(33)
        }
    }

    /// A placeholder line with a light sweeping across it (the Mac's SkeletonBar), `fraction` of
    /// the width. Redraws itself only while drawn.
    class SkeletonBar(context: android.content.Context, private val fraction: Float) : View(context) {
        private val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
        private val rect = android.graphics.RectF()
        init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }
        override fun onDraw(canvas: android.graphics.Canvas) {
            val w = width * fraction; val h = height.toFloat()
            if (w <= 0f) return
            val x = (phase(1.4) * 2 - 0.5).toFloat()
            paint.shader = android.graphics.LinearGradient((x - 0.6f) * w, 0f, (x + 0.6f) * w, 0f,
                intArrayOf(BASE, LIGHT, BASE), floatArrayOf(0f, 0.5f, 1f), android.graphics.Shader.TileMode.CLAMP)
            val r = minOf(6 * resources.displayMetrics.density, h / 2)
            rect.set(0f, 0f, w, h)
            canvas.drawRoundRect(rect, r, r, paint)
            if (android.animation.ValueAnimator.areAnimatorsEnabled()) postInvalidateDelayed(33)
        }
        companion object {
            private val BASE = android.graphics.Color.parseColor("#EEF0F3")
            private val LIGHT = android.graphics.Color.parseColor("#F7F8FA")
        }
    }

    /// Children left to right, wrapping to the next line (the Mac's FlowLayout), each row
    /// centred vertically.
    class FlowRow(context: android.content.Context, private val gap: Int) : android.view.ViewGroup(context) {
        private fun rows(max: Int): List<List<View>> {
            val rows = mutableListOf<MutableList<View>>(mutableListOf())
            var x = 0
            for (i in 0 until childCount) {
                val c = getChildAt(i)
                if (x > 0 && x + c.measuredWidth > max) { rows.add(mutableListOf()); x = 0 }
                rows.last().add(c); x += c.measuredWidth + gap
            }
            return rows
        }
        override fun onMeasure(widthSpec: Int, heightSpec: Int) {
            val max = MeasureSpec.getSize(widthSpec) - paddingLeft - paddingRight
            for (i in 0 until childCount) getChildAt(i).measure(MeasureSpec.makeMeasureSpec(max, MeasureSpec.AT_MOST), MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
            val rows = rows(max)
            val widest = rows.maxOf { r -> r.sumOf { it.measuredWidth } + gap * (r.size - 1).coerceAtLeast(0) }
            val h = rows.sumOf { r -> r.maxOfOrNull { it.measuredHeight } ?: 0 } + gap * (rows.size - 1)
            setMeasuredDimension(resolveSize(widest + paddingLeft + paddingRight, widthSpec), h + paddingTop + paddingBottom)
        }
        override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
            var y = paddingTop
            for (row in rows(r - l - paddingLeft - paddingRight)) {
                val rowH = row.maxOfOrNull { it.measuredHeight } ?: 0
                var x = paddingLeft
                for (c in row) {
                    val top = y + (rowH - c.measuredHeight) / 2
                    c.layout(x, top, x + c.measuredWidth, top + c.measuredHeight)
                    x += c.measuredWidth + gap
                }
                y += rowH + gap
            }
        }
    }

    fun bullet(ui: Ui, text: String, size: Float) = LinearLayout(ui.context).apply {
        orientation = LinearLayout.HORIZONTAL
        addView(ui.dot(Palette.tertiary, 5), LinearLayout.LayoutParams(ui.dp(5), ui.dp(5)).apply { topMargin = ui.dp((size * 0.72).toInt()); rightMargin = ui.dp(10); leftMargin = ui.dp(2) })
        addView(ui.text(text, size, Palette.ink).apply { leading(if (size >= Ui.Type.BODY) Ui.Type.LINE else 1.35f) }, ui.weight())
    }

    fun todo(ui: Ui, text: String) = LinearLayout(ui.context).apply {
        orientation = LinearLayout.HORIZONTAL
        addView(View(ui.context).apply { background = ui.rounded(0, 8, Palette.tertiary, 1.5) }, LinearLayout.LayoutParams(ui.dp(16), ui.dp(16)).apply { topMargin = ui.dp(5); rightMargin = ui.dp(10) })
        addView(ui.notesText(text), ui.weight())
    }
}
