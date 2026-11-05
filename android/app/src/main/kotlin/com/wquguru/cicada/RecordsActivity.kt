package com.wquguru.cicada

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import cicada.Languages
import cicada.Log
import cicada.NotesEngine
import cicada.Session
import cicada.SessionStore
import cicada.Strings.L
import cicada.Strings.LF
import cicada.SpeakerLabels
import cicada.Strings
import cicada.TranscriptExport

/// 会议记录: every meeting, newest first, grouped by day; search covers titles, notes and what
/// was said; chips narrow to meetings with notes or to-dos.
class RecordsActivity : Activity() {
    private lateinit var ui: Ui
    private lateinit var list: FrameLayout
    private lateinit var chips: LinearLayout
    private var query = ""
    private var filter = "all"
    private var shown: String? = null
    private var unobserve: (() -> Unit)? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ui = Ui(this)
        filter = savedInstanceState?.getString("filter") ?: "all"
        val search = EditText(this).apply {
            id = R.id.search
            hint = L("搜索会议、人名、词语")
            setSingleLine()
            background = null
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setPadding(0, 0, 0, 0)
            imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun afterTextChanged(s: Editable?) { query = s.toString().trim(); render() }
            })
        }
        val searchBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = ui.rounded(Palette.card, 26)
            ui.lift(this, 1)
            minimumHeight = ui.dp(52)
            setPadding(ui.dp(16), 0, ui.dp(16), 0)
            addView(ui.icon(R.drawable.i_search, 20, Palette.secondary))
            addView(search, ui.weight().apply { leftMargin = ui.dp(12) })
        }
        chips = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        list = FrameLayout(this)
        val body = ui.stack(12, searchBox, HorizontalScrollView(this).apply { isHorizontalScrollBarEnabled = false; addView(chips) }, list)
            .apply { setPadding(ui.dp(16), ui.dp(4), ui.dp(16), ui.dp(32)) }
        setContentView(ui.screen(this, null, back = true, ground = Palette.ground, body = body))
        // Opened from the floating search button: straight to typing.
        if (savedInstanceState == null) { search.requestFocus(); window.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE) }
    }

    override fun onResume() { super.onResume(); unobserve = cicada.observe(::render); shown = null; render() }
    override fun onPause() { super.onPause(); unobserve?.invoke(); unobserve = null }
    // The search text is kept by the field itself (it has an id); the filter by us.
    override fun onSaveInstanceState(out: Bundle) { super.onSaveInstanceState(out); out.putString("filter", filter) }

    private fun matches(s: Session): Boolean {
        if (filter == "notes" && (s.notes == null || s.notes!!.isEmpty)) return false
        if (filter == "todo" && (s.notes?.todos?.isEmpty() != false)) return false
        if (query.isEmpty()) return true
        val q = query.lowercase()
        return SessionStore.displayTitle(s).lowercase().contains(q) ||
            s.notes?.let { n -> (n.summary + n.topics.joinToString { it.title + it.points.joinToString() } + n.terms.joinToString { it.name }).lowercase().contains(q) } == true ||
            s.lines.any { it.src.lowercase().contains(q) || it.dst?.lowercase()?.contains(q) == true }
    }

    private fun render() {
        val app = cicada
        val sessions = app.store.all().filter(::matches)
        val liveId = if (app.listen.listening) app.listen.sessionId else null
        val key = "$query|$filter|$liveId|" + sessions.joinToString { "${it.id}:${SessionStore.displayTitle(it)}:${it.lines.size}:${it.endedAt}:${it.notes?.todos?.size}" }
        if (key == shown) return
        shown = key
        chips.removeAllViews()
        listOf("all" to L("全部"), "notes" to L("有纪要"), "todo" to L("有待办")).forEachIndexed { i, (v, label) ->
            chips.addView(ui.chip(label, filter == v) { filter = v; render() }, LinearLayout.LayoutParams(-2, -2).apply { if (i > 0) leftMargin = ui.dp(8) })
        }
        list.removeAllViews()
        if (sessions.isEmpty()) {
            list.addView(ui.helper(if (app.store.all().isEmpty()) L("还没有会议记录") else L("没有找到相关会议")).apply { setPadding(ui.dp(4), ui.dp(12), 0, 0) })
            return
        }
        val column = ui.stack(8)
        val days = LinkedHashMap<String, MutableList<Session>>()
        for (s in sessions) days.getOrPut(MainActivity.day(s.startedAt)) { mutableListOf() }.add(s)
        for ((day, items) in days) {
            column.addView(ui.sectionLabel(day))
            column.addView(ui.group(items.map { MainActivity.recordRow(this, ui, it, it.id == liveId) }))
        }
        list.addView(column)
    }
}

/// One meeting on one white sheet: who spoke (tap a name to change it), 纪要 or the bilingual
/// 文字记录, and the recording when it was kept (tap a line to hear it there). Export and the
/// rest are in the sheet behind 更多.
class RecordActivity : Activity() {
    private lateinit var ui: Ui
    private lateinit var id: String
    // A ListView, so a two-hour meeting's 1,500 lines are drawn as they scroll into view
    // rather than all at once (that froze the screen for over a second).
    private lateinit var list: android.widget.ListView
    private lateinit var header: FrameLayout
    private lateinit var footer: FrameLayout
    private lateinit var playerHost: FrameLayout
    private val adapter = LinesAdapter()
    private var tab = 0
    private var shown: String? = null
    private var unobserve: (() -> Unit)? = null
    private var player: android.media.MediaPlayer? = null
    private var playButton: android.widget.ImageView? = null
    private var playTime: TextView? = null
    private var playBar: LinearLayout? = null
    private var playing = -1 // the line being played, for the highlight
    private val tickPlayer = object : Runnable {
        override fun run() { updatePlayer(); if (player?.isPlaying == true) list.postDelayed(this, 250) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ui = Ui(this)
        id = intent.getStringExtra("id") ?: run { finish(); return }
        tab = savedInstanceState?.getInt("tab") ?: 0
        header = FrameLayout(this); footer = FrameLayout(this); playerHost = FrameLayout(this)
        list = android.widget.ListView(this).apply {
            divider = null
            selector = android.graphics.drawable.ColorDrawable(0)
            isVerticalScrollBarEnabled = false
            setPadding(0, 0, 0, ui.dp(40))
            clipToPadding = false
            addHeaderView(header, null, false)
            addFooterView(footer, null, false)
            adapter = this@RecordActivity.adapter
            setOnItemClickListener { _, _, pos, _ -> (pos - headerViewsCount).takeIf { it >= 0 }?.let { seekTo(it) } }
        }
        setContentView(ui.screen(this, null, back = true, ground = Palette.card, body = list, scroll = false, bottom = playerHost.takeIf { audio().isFile }, actions = listOf(
            ui.roundButton(R.drawable.i_share, L("分享"), onWhite = true) { cicada.store.get(id)?.let(::share) },
            ui.roundButton(R.drawable.i_more, L("更多"), onWhite = true) { more() })))
        if (audio().isFile) buildPlayer()
    }

    private fun audio() = cicada.store.audioFile(id)

    override fun onResume() { super.onResume(); unobserve = cicada.observe(::render); shown = null; render() }
    override fun onPause() { super.onPause(); unobserve?.invoke(); unobserve = null; player?.pause(); updatePlayer() }
    override fun onDestroy() { super.onDestroy(); player?.release(); player = null }

    private fun render() {
        val app = cicada
        val s = app.store.get(id) ?: run { if (app.store.loaded) finish(); return }
        val generating = app.notes.generating == id
        val key = listOf(SessionStore.displayTitle(s), s.lines.size, s.notes?.updatedAt, generating, app.notes.status, tab, s.lines.lastOrNull()?.dst,
                         s.voiceNames, app.settings.speakerVoices).joinToString("|")
        if (key == shown) return
        shown = key
        val top = ui.stack(0).apply { setPadding(ui.dp(20), ui.dp(4), ui.dp(20), ui.dp(6)) }
        top.addView(ui.title(SessionStore.displayTitle(s), 28f).apply { leading(1.2f) })
        val first = s.lines.firstOrNull()
        val meta = listOfNotNull("${MainActivity.day(s.startedAt)} ${MainActivity.time(s.startedAt)}", Languages.clock(s.durationSeconds),
                                 first?.let { "${NotesViews.languageName(it.srcLang)} → ${NotesViews.languageName(it.dstLang)}" },
                                 s.sourceFile?.let { L("导入") }).joinToString(" · ")
        top.addView(ui.text(meta, 13f, Palette.secondary), ui.lp(top = 6))
        speakerChips(s)?.let { top.addView(it, ui.lp(top = 14)) }
        top.addView(ui.tabs(listOf(L("纪要"), "${L("文字记录")} · ${s.lines.size} ${L("句")}"), tab) { tab = it; render() }, ui.lp(top = 18))
        header.removeAllViews(); header.addView(top)

        val bottom = ui.stack(0).apply { setPadding(ui.dp(20), 0, ui.dp(20), 0) }
        if (tab == 0) {
            val n = s.notes
            when {
                n != null && !n.isEmpty ->
                    bottom.addView(NotesViews.notesBody(ui, n, NotesEngine.State.Idle, false).apply { (getChildAt(0) as? LinearLayout)?.visibility = View.GONE }, ui.lp(top = 6))
                generating -> bottom.addView(ui.text(L("正在整理纪要…"), 15f, Palette.secondary), ui.lp(top = 24))
                else -> {
                    if (app.notes.status == NotesEngine.State.Failed) bottom.addView(ui.text(L("纪要没生成出来，稍后再试"), 15f, Palette.link), ui.lp(top = 24))
                    val live = app.listen.listening && app.listen.sessionId == id
                    if (!live) bottom.addView(ui.button(L("生成纪要"), "primary") { app.notes.generate(id) }, ui.lp(top = 20))
                }
            }
        }
        footer.removeAllViews(); footer.addView(bottom)
        val lines = if (tab == 1) app.store.lines(id) else emptyList()
        adapter.show(lines, SpeakerLabels.numbers(lines), SpeakerLabels.names(s), s.sourceFile == null)
    }

    /// The voices told apart (in records from the Mac or Windows): a chip each; a tap names it.
    private fun speakerChips(s: Session): View? {
        val numbers = SpeakerLabels.numbers(s.lines)
        if (numbers.isEmpty()) return null
        val names = SpeakerLabels.names(s)
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        numbers.values.toSortedSet().forEachIndexed { i, n ->
            val (bg, fg) = NotesViews.voiceColor(n)
            val label = SpeakerLabels.label(n, names)
            row.addView(ui.text(label, 13f, fg, bold = true, lines = 1).apply {
                gravity = android.view.Gravity.CENTER
                minHeight = ui.dp(36)
                setPadding(ui.dp(14), 0, ui.dp(14), 0)
                contentDescription = label + "，" + L("改名")
                ui.tappable(this, 18, ui.rounded(bg, 18)) { nameVoice(s, n, label) }
            }, LinearLayout.LayoutParams(-2, -2).apply { if (i > 0) leftMargin = ui.dp(8) })
        }
        return HorizontalScrollView(this).apply { isHorizontalScrollBarEnabled = false; addView(row) }
    }

    /// The Mac's 改说话人: the name goes on the voice, so every line, the notes and exports follow.
    private fun nameVoice(s: Session, number: Int, shownName: String) {
        val voice = SpeakerLabels.voiceOf(s.lines, number) ?: return
        ui.input(this, LF("%@ 是谁？", shownName), SpeakerLabels.names(s)[number] ?: "", helper = L("只改这场会议，前面的字幕和纪要一起改"),
                 hint = Strings.LF("说话人 %lld", number)) { name ->
            cicada.store.setVoiceName(s.id, voice, name.ifEmpty { null })
        }
    }

    /// One transcript line per row: time, who, what was said, its translation. Rows are reused.
    private inner class LinesAdapter : android.widget.BaseAdapter() {
        private var lines: List<cicada.TranscriptLine> = emptyList()
        private var numbers: Map<String, Int> = emptyMap()
        private var names: Map<Int, String> = emptyMap()
        private var who = true
        fun show(l: List<cicada.TranscriptLine>, n: Map<String, Int>, nm: Map<Int, String>, speakers: Boolean) {
            lines = l; numbers = n; names = nm; who = speakers; notifyDataSetChanged()
        }
        override fun getCount() = lines.size
        override fun getItem(i: Int) = lines[i]
        override fun getItemId(i: Int) = i.toLong()

        override fun getView(i: Int, convertView: View?, parent: android.view.ViewGroup?): View {
            val row = convertView as? LinearLayout ?: LinearLayout(this@RecordActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(ui.dp(20), ui.dp(14), ui.dp(20), ui.dp(14))
                addView(ui.text("", 12f, Palette.tertiary).apply { fontFeatureSettings = "tnum" }, LinearLayout.LayoutParams(ui.dp(44), -2).apply { topMargin = ui.dp(2) })
                addView(ui.stack(3,
                    ui.text("", 12f, Palette.secondary, bold = true, lines = 1),
                    ui.text("", Ui.Type.ORIGINAL, Palette.secondary).apply { leading(1.45f) },
                    ui.text("", Ui.Type.BODY, Palette.ink).apply { leading(1.5f) }), ui.weight())
            }
            val l = lines[i]
            val now = i == playing
            row.setBackgroundColor(if (now) 0x0FE8552B else 0)
            (row.getChildAt(0) as TextView).apply { text = Languages.clock(l.t); setTextColor(if (now) Palette.link else Palette.tertiary) }
            val texts = row.getChildAt(1) as LinearLayout
            val name = SpeakerLabels.speakerName(l, numbers, names)
            (texts.getChildAt(0) as TextView).apply {
                text = name
                visibility = if (who) View.VISIBLE else View.GONE
                setTextColor(if (l.speaker == "me") Palette.ink else NotesViews.voiceColor(numbers[l.id]).second.takeIf { numbers[l.id] != null } ?: Palette.secondary)
            }
            val translated = !l.dst.isNullOrEmpty() && l.dst != l.src
            (texts.getChildAt(1) as TextView).apply { text = l.src; visibility = if (translated) View.VISIBLE else View.GONE }
            (texts.getChildAt(2) as TextView).text = if (translated) l.dst else l.src
            return row
        }
    }

    override fun onSaveInstanceState(out: Bundle) { super.onSaveInstanceState(out); out.putInt("tab", tab) }

    // MARK: The recording (保存会议录音)

    private fun buildPlayer() {
        val play = android.widget.ImageView(this).apply { setImageDrawable(ui.drawable(R.drawable.i_play, android.graphics.Color.WHITE)); importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }
        val button = FrameLayout(this).apply {
            contentDescription = L("播放原声")
            addView(play, FrameLayout.LayoutParams(ui.dp(20), ui.dp(20), android.view.Gravity.CENTER))
            ui.tappable(this, 24, ui.rounded(Palette.ink, 24), dark = true) { toggle() }
        }
        val bar = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; background = ui.rounded(Palette.line, 2); weightSum = 1f
            addView(View(context).apply { background = ui.rounded(Palette.accent, 2) }, LinearLayout.LayoutParams(0, -1, 0f)) }
        val time = ui.text("00:00", 11f, Palette.secondary).apply { fontFeatureSettings = "tnum" }
        val pill = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = android.view.Gravity.CENTER_VERTICAL
            // On the white page a shadow alone doesn't separate it: a hairline too.
            background = ui.rounded(Palette.card, 32, Palette.line, 1)
            ui.lift(this, 6)
            setPadding(ui.dp(8), ui.dp(8), ui.dp(18), ui.dp(8))
            addView(button, LinearLayout.LayoutParams(ui.dp(48), ui.dp(48)))
            addView(ui.stack(6, bar.apply { layoutParams = LinearLayout.LayoutParams(-1, ui.dp(4)) }, time), ui.weight().apply { leftMargin = ui.dp(14) })
        }
        playButton = play; playTime = time; playBar = bar
        playerHost.addView(LinearLayout(this).apply {
            background = ui.fade(Palette.card)
            setPadding(ui.dp(16), ui.dp(28), ui.dp(16), ui.dp(16))
            addView(pill, LinearLayout.LayoutParams(-1, ui.dp(64)))
        })
        updatePlayer()
    }

    private fun ensurePlayer(): android.media.MediaPlayer? {
        player?.let { return it }
        return try {
            android.media.MediaPlayer().apply {
                setDataSource(audio().path); prepare()
                setOnCompletionListener { updatePlayer() }
            }.also { player = it }
        } catch (e: Exception) { Log.d("record: play failed ${e.javaClass.simpleName}"); null }
    }

    private fun toggle() {
        val p = ensurePlayer() ?: return
        if (p.isPlaying) p.pause() else { p.start(); list.post(tickPlayer) }
        updatePlayer()
    }

    /// A tap on a line plays the recording from there.
    private fun seekTo(index: Int) {
        if (!audio().isFile) return
        val l = adapter.getItem(index)
        val p = ensurePlayer() ?: return
        p.seekTo((l.t * 1000).toInt())
        if (!p.isPlaying) { p.start(); list.post(tickPlayer) }
        updatePlayer()
    }

    private fun updatePlayer() {
        val p = player
        val pos = (p?.currentPosition ?: 0) / 1000.0
        val dur = (p?.duration ?: 0).takeIf { it > 0 }?.div(1000.0) ?: cicada.store.get(id)?.durationSeconds ?: 0.0
        playButton?.setImageDrawable(ui.drawable(if (p?.isPlaying == true) R.drawable.i_pause else R.drawable.i_play, android.graphics.Color.WHITE))
        playTime?.text = "${Languages.clock(pos)} / ${Languages.clock(dur)}"
        playBar?.getChildAt(0)?.let { (it.layoutParams as LinearLayout.LayoutParams).weight = if (dur > 0) (pos / dur).toFloat().coerceIn(0f, 1f) else 0f; it.requestLayout() }
        // The line being heard, highlighted.
        val lines = (0 until adapter.count).map { adapter.getItem(it) }
        val now = if (p?.isPlaying == true || pos > 0) lines.indexOfLast { it.t <= pos } else -1
        if (now != playing) { playing = now; adapter.notifyDataSetChanged() }
    }

    // MARK: 更多: export and the rest

    private fun more() {
        val s = cicada.store.get(id) ?: return
        lateinit var d: android.app.Dialog
        fun act(res: Int, label: String, helper: String? = null, red: Boolean = false, run: () -> Unit) = ui.sheetAction(res, label, helper, red) { d.dismiss(); run() }
        val box = ui.stack(0,
            act(R.drawable.i_clipboard, L("复制为 Markdown")) { copy(s) },
            act(R.drawable.i_doc, L("导出 Markdown…")) { export(s, "md") },
            act(R.drawable.i_doc, L("导出 Word…")) { export(s, "docx") },
            act(R.drawable.i_captions, L("导出字幕 SRT…"), L("配回原视频用")) { export(s, "srt") })
        box.addView(View(this).apply { setBackgroundColor(Palette.divider) }, LinearLayout.LayoutParams(-1, 1).apply { setMargins(ui.dp(8), ui.dp(8), ui.dp(8), ui.dp(8)) })
        box.addView(act(R.drawable.i_edit, L("重命名")) { rename(s) })
        // As on the Mac: back to the notes' name once the user named it themselves.
        if ((s.renamed ?: !s.title.startsWith("会议 ")) && s.notes?.title != null) box.addView(act(R.drawable.i_restore, L("恢复自动标题")) { cicada.store.rename(s.id, "") })
        // The meeting being listened to can't be deleted (its next lines would vanish).
        if (cicada.store.liveId != s.id) box.addView(act(R.drawable.i_trash, L("删除"), red = true) { delete(s) })
        d = ui.sheet(this, null, box)
        d.show()
    }

    /// The Markdown through the share sheet (chat apps, notes apps, Files…).
    private fun share(s: Session) {
        val send = Intent(Intent.ACTION_SEND).setType("text/plain")
            .putExtra(Intent.EXTRA_SUBJECT, SessionStore.displayTitle(s))
            .putExtra(Intent.EXTRA_TEXT, TranscriptExport.markdown(s))
        startActivity(Intent.createChooser(send, L("分享")))
    }

    private fun copy(s: Session) {
        getSystemService(android.content.ClipboardManager::class.java).setPrimaryClip(android.content.ClipData.newPlainText(SessionStore.displayTitle(s), TranscriptExport.markdown(s)))
        // Android 13+ confirms a copy itself; older versions get a toast.
        if (android.os.Build.VERSION.SDK_INT < 33) android.widget.Toast.makeText(this, L("已复制"), android.widget.Toast.LENGTH_SHORT).show()
    }

    private var exportKind = "md"

    /// Saves a file where the user picks (the system file picker), in the Mac's formats.
    private fun export(s: Session, kind: String) {
        exportKind = kind
        val type = when (kind) { "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"; "srt" -> "application/x-subrip"; else -> "text/markdown" }
        @Suppress("DEPRECATION")
        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType(type).putExtra(Intent.EXTRA_TITLE, TranscriptExport.fileName(s, kind)), 7)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val uri = data?.data ?: return
        val s = cicada.store.get(id) ?: return
        if (requestCode == 7 && resultCode == RESULT_OK) {
            val bytes = when (exportKind) { "docx" -> TranscriptExport.docx(s); "srt" -> TranscriptExport.srt(s).toByteArray(); else -> TranscriptExport.markdown(s).toByteArray() }
            try { contentResolver.openOutputStream(uri)?.use { it.write(bytes) }; Log.d("export: $exportKind ${bytes.size} bytes") }
            catch (e: Exception) { Log.d("export failed ${e.javaClass.simpleName}") }
        }
    }

    private fun rename(s: Session) {
        val shown = MainActivity.name(s)
        // Untouched changes nothing; emptied goes back to the automatic title (the store's rule).
        ui.input(this, L("重命名"), shown) { if (it != shown) cicada.store.rename(s.id, it) }
    }

    private fun delete(s: Session) {
        ui.confirm(this, L("删除"), LF("删除“%@”？删掉后不能恢复", SessionStore.displayTitle(s)), ok = L("删除"), destructive = true) { cicada.store.delete(s.id); finish() }
    }
}
