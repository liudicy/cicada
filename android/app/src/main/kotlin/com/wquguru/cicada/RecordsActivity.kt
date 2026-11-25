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
import cicada.TranscriptSearch

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
        // Debug `search <text>`: typed in, as a person would.
        if (savedInstanceState == null) intent.getStringExtra("query")?.let { search.setText(it) }
    }

    override fun onResume() { super.onResume(); current = this; unobserve = cicada.observe(::render); shown = null; render() }
    override fun onPause() { super.onPause(); if (current === this) current = null; unobserve?.invoke(); unobserve = null }

    /// For `cicadactl search`: the meetings the search finds (ids), and opening one as a tap does.
    fun debugFound(): List<String> = cicada.store.all().filter(::matches).map { it.id }
    fun debugOpen(index: Int): String? {
        val id = debugFound().getOrNull(index) ?: return null
        val s = cicada.store.get(id) ?: return null
        MainActivity.recordRow(this, ui, s, cicada.listen.listening && cicada.listen.sessionId == id, query).performClick()
        return id
    }

    companion object {
        /// 会议记录 in front, for the debug commands.
        var current: RecordsActivity? = null; private set
    }
    // The search text is kept by the field itself (it has an id); the filter by us.
    override fun onSaveInstanceState(out: Bundle) { super.onSaveInstanceState(out); out.putString("filter", filter) }

    private fun matches(s: Session): Boolean {
        if (filter == "notes" && (s.notes == null || s.notes!!.isEmpty)) return false
        if (filter == "todo" && (s.notes?.todos?.isEmpty() != false)) return false
        if (query.isEmpty()) return true
        val q = query.lowercase()
        // What was said is searched as the record will mark it: misheard names too (TranscriptSearch).
        val terms = TranscriptSearch.terms(query, s.notes?.terms.orEmpty())
        return SessionStore.displayTitle(s).lowercase().contains(q) ||
            s.notes?.let { n -> (n.summary + n.topics.joinToString { it.title + it.points.joinToString() } + n.terms.joinToString { it.name }).lowercase().contains(q) } == true ||
            s.lines.any { TranscriptSearch.matches(it, terms) }
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
            column.addView(ui.group(items.map { MainActivity.recordRow(this, ui, it, it.id == liveId, query) }))
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
    // Once the big title scrolls away: the title in the top bar (a tap goes back up) and the
    // tabs pinned under it, as the Mac's pinned bar.
    private lateinit var barTitle: TextView
    private lateinit var pinnedTabs: FrameLayout
    private var headTitle: View? = null
    private var headTabs: View? = null
    private val adapter = LinesAdapter()
    private var tab = 0
    private var shown: String? = null
    private var unobserve: (() -> Unit)? = null
    private var player: android.media.MediaPlayer? = null
    private var playButton: android.widget.ImageView? = null
    private var playFrame: View? = null
    private var playTime: TextView? = null
    private var playLength: TextView? = null
    private var speedLabel: TextView? = null
    private var scrubber: Scrubber? = null
    private var speed = 1f
    // The file is there but MediaPlayer can't open it: said as 找不到录音 instead of a dead bar.
    private var broken = false
    private var playing: String? = null // the line at the playhead, for the highlight
    private var playingOn = false // and whether it is sounding (its bars bounce)
    /// The transcript keeps the playing line centred. Scrolling it by finger stops that until a
    /// line is tapped, the bar is used or 回到正在播放 is pressed: following would yank the page away.
    private var following = true
    private lateinit var backToPlaying: LinearLayout
    private lateinit var backToPlayingText: TextView
    private var toast: FixViews.Toast? = null
    /// Opened from 会议记录's search (#33): what was searched, the lines it finds here (misheard
    /// names too), which one is being looked at, and whether the page still has to go to it.
    private var query = ""
    private var terms: List<String> = emptyList()
    private var found: List<String> = emptyList()
    private var matchIndex = 0
    private var landing = false
    private lateinit var matchBar: LinearLayout
    private lateinit var matchLabel: TextView
    private val tickPlayer = object : Runnable {
        override fun run() { updatePlayer(); if (player?.isPlaying == true) list.postDelayed(this, 250) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ui = Ui(this)
        id = intent.getStringExtra("id") ?: run { finish(); return }
        tab = savedInstanceState?.getInt("tab") ?: 0
        query = intent.getStringExtra("query")?.trim() ?: ""
        matchIndex = savedInstanceState?.getInt("match") ?: 0
        landing = savedInstanceState == null && query.isNotEmpty()
        header =FrameLayout(this); footer = FrameLayout(this); playerHost = FrameLayout(this)
        list = android.widget.ListView(this).apply {
            divider = null
            selector = android.graphics.drawable.ColorDrawable(0)
            isVerticalScrollBarEnabled = false
            setPadding(0, 0, 0, ui.dp(40))
            clipToPadding = false
            addHeaderView(header, null, false)
            addFooterView(footer, null, false)
            adapter = this@RecordActivity.adapter
            setOnItemClickListener { _, _, pos, _ -> (pos - headerViewsCount).takeIf { it in 0 until this@RecordActivity.adapter.count }?.let { playFrom(this@RecordActivity.adapter.getItem(it).t) } }
            // 改正听错的词: a long press shows what a line's fixed words were heard as (改回) and 改这句….
            setOnItemLongClickListener { _, _, pos, _ -> (pos - headerViewsCount).takeIf { it in 0 until this@RecordActivity.adapter.count }?.let { FixViews.lineSheet(this@RecordActivity, ui, cicada, this@RecordActivity.id, this@RecordActivity.adapter.getItem(it)) } != null }
            setOnScrollListener(object : android.widget.AbsListView.OnScrollListener {
                override fun onScrollStateChanged(v: android.widget.AbsListView, state: Int) {}
                override fun onScroll(v: android.widget.AbsListView, first: Int, visible: Int, total: Int) = pin()
            })
            // A finger dragging the list stops following. Not the scroll state: a touch that only
            // catches following's own centring (or a tap during it) reports TOUCH_SCROLL too.
            val slop = android.view.ViewConfiguration.get(context).scaledTouchSlop
            var downY = 0f
            setOnTouchListener { _, e ->
                when (e.actionMasked) {
                    android.view.MotionEvent.ACTION_DOWN -> downY = e.y
                    android.view.MotionEvent.ACTION_MOVE -> if (following && player?.isPlaying == true && Math.abs(e.y - downY) > slop) { following = false; showBackToPlaying() }
                }
                false
            }
        }
        barTitle = ui.text("", 17f, Palette.ink, bold = true, lines = 1).apply {
            alpha = 0f
            setPadding(ui.dp(8), 0, ui.dp(8), 0)
            setOnClickListener { list.setSelection(0) }
            isClickable = false
        }
        pinnedTabs = FrameLayout(this).apply {
            setBackgroundColor(Palette.card)
            setPadding(ui.dp(20), ui.dp(6), ui.dp(20), ui.dp(10))
            visibility = View.GONE
            isClickable = true // taps on its edges don't reach the lines under it
        }
        // The player floats over the bottom of the page (not screen()'s bottom bar), so render()
        // can show it once a live meeting ends and its recording is in place.
        playerHost.visibility = View.GONE
        // Scrolled away from what is playing: one way back, just above the player.
        backToPlayingText = ui.text("", 13f, android.graphics.Color.WHITE, bold = true, lines = 1).apply { fontFeatureSettings = "tnum" }
        backToPlaying = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = android.view.Gravity.CENTER_VERTICAL
            setPadding(ui.dp(16), 0, ui.dp(16), 0)
            minimumHeight = ui.dp(36)
            addView(ui.icon(R.drawable.i_waves, 14, android.graphics.Color.WHITE).apply { importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO })
            addView(backToPlayingText, LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(6) })
            ui.tappable(this, 18, ui.rounded(Palette.ink, 18), dark = true) { follow() }
            elevation = ui.dp(4).toFloat()
            visibility = View.GONE
        }
        // Where the search is in this meeting: 本场 2 / 7, and the previous and next line found.
        // Under the pinned tabs, so it stays while the transcript scrolls.
        matchLabel = ui.text("", 13f, Palette.secondary, lines = 1).apply { fontFeatureSettings = "tnum" }
        matchBar = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Palette.card)
            isClickable = true // taps on it don't reach the lines under it
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = android.view.Gravity.CENTER_VERTICAL
                setPadding(ui.dp(20), 0, ui.dp(8), 0)
                minimumHeight = ui.dp(48)
                addView(matchLabel, ui.weight())
                addView(ui.iconButton(R.drawable.i_chevron_down, L("上一个"), Palette.secondary, size = 20) { step(-1) }.apply { getChildAt(0).rotation = 180f })
                addView(ui.iconButton(R.drawable.i_chevron_down, L("下一个"), Palette.secondary, size = 20) { step(1) })
            })
            addView(View(context).apply { setBackgroundColor(Palette.divider) }, LinearLayout.LayoutParams(-1, 1))
            visibility = View.GONE
        }
        // Moved, not laid out, under the tabs: pin() runs inside the list's layout, where a
        // relayout of its neighbours would be missed.
        pinnedTabs.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> placeMatchBar() }
        val body = FrameLayout(this).apply {
            addView(list, FrameLayout.LayoutParams(-1, -1))
            addView(matchBar, FrameLayout.LayoutParams(-1, -2, android.view.Gravity.TOP))
            addView(pinnedTabs, FrameLayout.LayoutParams(-1, -2, android.view.Gravity.TOP))
            addView(playerHost, FrameLayout.LayoutParams(-1, -2, android.view.Gravity.BOTTOM))
            addView(backToPlaying, FrameLayout.LayoutParams(-2, -2, android.view.Gravity.BOTTOM or android.view.Gravity.CENTER_HORIZONTAL).apply { bottomMargin = ui.dp(112) })
        }
        setContentView(ui.screen(this, null, back = true, ground = Palette.card, body = body, scroll = false, center = barTitle, actions = listOf(
            ui.roundButton(R.drawable.i_share, L("分享"), onWhite = true) { cicada.store.get(id)?.let(::share) },
            ui.roundButton(R.drawable.i_more, L("更多"), onWhite = true) { more() })))
        toast = FixViews.Toast(this, ui, cicada, above = 140)
        // Debug `shareSheet <id>`: the 分享… sheet opens over the record.
        if (savedInstanceState == null && intent.getBooleanExtra("share", false))
            list.post { cicada.store.get(id)?.takeIf { ShareSheet.canShare(cicada, it) }?.let { ShareSheet(this, ui, id).show() } }
    }

    private fun audio() = cicada.store.audioFile(id)

    /// The banner's line, in view: the transcript tab, scrolled to it.
    private fun show(lineId: String) {
        val i = adapter.indexOf(lineId)
        if (i >= 0) list.post { list.setSelectionFromTop(i + list.headerViewsCount, ui.dp(160)) }
    }

    // MARK: The search it was opened from (the Mac's 本场 n / N)

    private fun currentMatch(): String? = found.getOrNull(matchIndex.coerceIn(0, maxOf(0, found.size - 1)))

    /// To the previous (-1) or next (1) line found, round the ends, on the transcript.
    fun step(d: Int) {
        val n = found.size
        if (n == 0) return
        matchIndex = (matchIndex.coerceIn(0, n - 1) + d + n) % n
        if (tab != 1) { tab = 1; render() }
        // While the recording plays, going to a line found stops following it, as a finger does:
        // otherwise the next line heard yanks the page back within seconds.
        if (following && player?.isPlaying == true) { following = false; showBackToPlaying() }
        showMatchBar()
        adapter.notifyDataSetChanged()
        list.post { goToMatch() }
        Log.d("record search: ${matchIndex + 1}/$n at ${currentMatch()}")
    }

    /// The line found, in the middle of the page. A jump from far away lands by a guessed row
    /// height and before the tabs pin, so once laid out it is centred again, exactly.
    private fun goToMatch() {
        val i = adapter.indexOf(currentMatch())
        if (i < 0) return
        val pos = i + list.headerViewsCount
        val far = list.getChildAt(pos - list.firstVisiblePosition) == null
        centre(i)
        if (far) list.postDelayed({
            val row = list.getChildAt(pos - list.firstVisiblePosition) ?: return@postDelayed
            val top = (if (pinnedTabs.visibility == View.VISIBLE) pinnedTabs.height else 0) + matchBar.height
            val bottom = list.height - (if (playerHost.visibility == View.VISIBLE) playerHost.height else 0)
            list.setSelectionFromTop(pos, top + maxOf(0, (bottom - top - row.height) / 2))
        }, 150)
    }

    private fun showMatchBar() {
        val n = found.size
        matchBar.visibility = if (n > 0) View.VISIBLE else View.GONE
        if (n > 0) matchLabel.text = LF("本场 %lld / %lld", matchIndex.coerceIn(0, n - 1) + 1, n)
    }

    /// Every term in a line marked in place; the line being looked at stands out from the rest.
    private fun marked(text: CharSequence, current: Boolean): CharSequence {
        val ranges = TranscriptSearch.ranges(text.toString(), terms)
        if (ranges.isEmpty()) return text
        val s = android.text.SpannableString(text)
        for (r in ranges) {
            s.setSpan(android.text.style.BackgroundColorSpan(if (current) Palette.accent else Palette.accentPale), r.first, r.last + 1, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            s.setSpan(android.text.style.ForegroundColorSpan(if (current) android.graphics.Color.WHITE else Palette.link), r.first, r.last + 1, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        return s
    }

    /// The title moves into the top bar once the big one is out of sight, and the tabs pin once
    /// theirs scroll under the top edge (the header leaves the list entirely far down a transcript).
    private fun pin() {
        // The list reports a scroll as soon as the listener is set, before the views below exist.
        if (!::list.isInitialized || !::barTitle.isInitialized || !::pinnedTabs.isInitialized || !::matchBar.isInitialized) return
        val gone = list.firstVisiblePosition > 0
        val top = header.top
        // Under the search's bar the tabs are already out of sight.
        val inset = if (matchBar.visibility == View.VISIBLE) matchBar.height else 0
        fun above(v: View?, by: Int = 0) = gone || (v != null && top + (v.parent as View).top + v.bottom <= by)
        val titleAway = above(headTitle)
        if (titleAway != barTitle.isClickable) barTitle.animate().alpha(if (titleAway) 1f else 0f).setDuration(150).start()
        barTitle.isClickable = titleAway
        barTitle.contentDescription = if (titleAway) L("回到顶部") else null
        pinnedTabs.visibility = if (above(headTabs, inset)) View.VISIBLE else View.GONE
        placeMatchBar()
    }

    private fun placeMatchBar() {
        matchBar.translationY = if (pinnedTabs.visibility == View.VISIBLE) pinnedTabs.height.toFloat() else 0f
    }

    override fun onResume() { super.onResume(); current = this; unobserve = cicada.observe(::render); shown = null; render() }
    // Leaving the record (back, another screen, the phone locked) stops what it was playing.
    // Only a playing player is paused: pause() on one that never started puts MediaPlayer in its
    // error state (the bar came back with a length of 00:00).
    override fun onPause() { super.onPause(); if (current === this) current = null; unobserve?.invoke(); unobserve = null; player?.takeIf { it.isPlaying }?.pause(); if (isFinishing) releasePlayer() else updatePlayer() }
    override fun onDestroy() { super.onDestroy(); releasePlayer() }

    private fun render() {
        val app = cicada
        val s = app.store.get(id) ?: run { if (app.store.loaded) finish(); return }
        toast?.refresh()
        val generating = app.notes.generating == id
        val live = app.listen.listening && app.listen.sessionId == id
        val file = !live && audio().isFile
        if (!file) releasePlayer() else if (player == null && !broken) broken = ensurePlayer() == null
        val playable = file && !broken
        terms = TranscriptSearch.terms(query, s.notes?.terms.orEmpty())
        found = TranscriptSearch.matches(app.store.lines(id), terms)
        // Opened by a search that finds lines here: their transcript, at the first one.
        if (landing && app.store.lines(id).isNotEmpty()) {
            landing = false
            if (found.isNotEmpty()) { tab = 1; matchIndex = 0; list.post { goToMatch() } }
            Log.d("record search: ${found.size} matches, at ${currentMatch() ?: "-"}")
        }
        val key = listOf(found.size,SessionStore.displayTitle(s), s.lines.size, s.notes?.updatedAt, generating, app.notes.status, tab, s.lines.lastOrNull()?.dst,
                         s.voiceNames, app.settings.speakerVoices, live, s.hasAudio, playable, app.settings.recordAudio, app.store.lines(id).sumOf { it.fixes?.hashCode() ?: 0 }, app.fixes.pending(id).size, app.folderExport.stateKey(), app.folderExport.file(id), app.folderExport.isPending(id)).joinToString("|")
        if (key == shown) return
        shown = key
        showMatchBar()
        // The search's bar sits over the top of the page: the title starts under it.
        val top = ui.stack(0).apply { setPadding(ui.dp(20), ui.dp(if (found.isEmpty()) 4 else 52), ui.dp(20), ui.dp(6)) }
        val title = ui.title(SessionStore.displayTitle(s), 28f).apply { leading(1.2f) }
        top.addView(title)
        headTitle = title
        barTitle.text = SessionStore.displayTitle(s)
        val first = s.lines.firstOrNull()
        val meta = listOfNotNull("${MainActivity.day(s.startedAt)} ${MainActivity.time(s.startedAt)}", Languages.clock(s.durationSeconds),
                                 first?.let { "${NotesViews.languageName(it.srcLang)} → ${NotesViews.languageName(it.dstLang)}" },
                                 s.sourceFile?.let { L("导入") }).joinToString(" · ")
        top.addView(ui.text(meta, 13f, Palette.secondary), ui.lp(top = 6))
        recordingNote(s, live, file, playable)?.let { top.addView(it, ui.lp(top = 6)) }
        // 存到文件夹: where its file is, or why it isn't there yet.
        if (!live) FolderExportViews.recordLine(this, ui, s)?.let { top.addView(it, ui.lp(top = 2)) }
        speakerChips(s)?.let { top.addView(it, ui.lp(top = 14)) }
        val tabLabels = listOf(L("纪要"), "${L("文字记录")} · ${LF("%lld 句", s.lines.size)}")
        val tabs = ui.tabs(tabLabels, tab) { tab = it; render() }
        top.addView(tabs, ui.lp(top = 18))
        // Over a finished meeting's transcript: the words fixed, and those waiting for the user.
        if (tab == 1 && !live) FixViews.reviewBanner(ui, app.fixes, s, onShow = { show(it) }, onEdit = { l, start -> FixViews.edit(this, ui, app, id, l, start) })
            ?.let { top.addView(it, ui.lp(top = 14)) }
        headTabs = tabs
        header.removeAllViews(); header.addView(top)
        pinnedTabs.removeAllViews()
        pinnedTabs.addView(ui.tabs(tabLabels, tab) { tab = it; render() })

        val bottom = ui.stack(0).apply { setPadding(ui.dp(20), 0, ui.dp(20), 0) }
        if (tab == 0) {
            val n = s.notes
            when {
                n != null && !n.isEmpty ->
                    bottom.addView(NotesViews.notesBody(ui, n, NotesEngine.State.Idle, false).apply { (getChildAt(0) as? LinearLayout)?.visibility = View.GONE }, ui.lp(top = 6))
                generating -> bottom.addView(ui.text(L("正在整理纪要…"), 15f, Palette.secondary), ui.lp(top = 24))
                else -> {
                    if (app.notes.status == NotesEngine.State.Failed) bottom.addView(ui.text(L("纪要没生成出来，稍后再试"), 15f, Palette.link), ui.lp(top = 24))
                    if (!live) bottom.addView(ui.button(L("生成纪要"), "primary") { app.notes.generate(id) }, ui.lp(top = 20))
                }
            }
        }
        footer.removeAllViews(); footer.addView(bottom)
        if (playable && playerHost.childCount == 0) buildPlayer()
        playerHost.visibility = if (playable) View.VISIBLE else View.GONE
        // The last lines end above the floating player, but scroll under it.
        list.setPadding(0, 0, 0, ui.dp(if (playable) 124 else 40))
        val lines = if (tab == 1) app.store.lines(id) else emptyList()
        val numbers = SpeakerLabels.numbers(lines)
        adapter.show(lines, numbers, SpeakerLabels.names(s), SpeakerLabels.saysWho(s, numbers), playable)
        updatePlayer()
    }

    /// One grey line under the date when there is nothing to play: why, and where to change it.
    private fun recordingNote(s: Session, live: Boolean, file: Boolean, playable: Boolean): View? {
        fun note(text: String) = ui.text(text, 12f, Palette.secondary)
        return when {
            playable -> null
            live -> if (cicada.settings.recordAudio) note(L("会议结束后可以回放录音")) else null
            // Just ended: the recorder is still closing the file (the page updates once it's in place).
            java.io.File(audio().path + ".partial").isFile -> null
            file || s.hasAudio -> note(L("找不到录音，没法播放"))
            s.lines.isEmpty() -> null
            else -> LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = android.view.Gravity.CENTER_VERTICAL
                addView(note(L("这场会议没存录音 ·")))
                addView(ui.text(L("保存会议录音"), 12f, Palette.link, bold = true).apply {
                    setPadding(ui.dp(4), ui.dp(8), ui.dp(4), ui.dp(8))
                    ui.tappable(this, 8) { startActivity(Intent(this@RecordActivity, SettingsActivity::class.java)) }
                })
            }
        }
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
        private var playable = false
        fun show(l: List<cicada.TranscriptLine>, n: Map<String, Int>, nm: Map<Int, String>, speakers: Boolean, canPlay: Boolean) {
            lines = l; numbers = n; names = nm; who = speakers; playable = canPlay; notifyDataSetChanged()
        }
        fun indexOf(lineId: String?) = if (lineId == null) -1 else lines.indexOfFirst { it.id == lineId }
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
                addView(PlayingBars(), LinearLayout.LayoutParams(ui.dp(14), ui.dp(12)).apply { leftMargin = ui.dp(8); topMargin = ui.dp(4) })
            }
            val l = lines[i]
            val now = l.id == playing
            // With a recording the whole row plays from its line (the list's item click): the line
            // at the playhead on the pale accent, a grey press on the others; the fill reaches 10dp
            // past the text, as the Mac's.
            row.background = if (!playable) null else android.graphics.drawable.InsetDrawable(
                ui.ripple(if (now) ui.rounded(PLAYING_LINE, 10) else null, 10), ui.dp(10), 0, ui.dp(10), 0)
            // A background with insets brings its own padding: the row's goes back on after it.
            row.setPadding(ui.dp(20), ui.dp(14), ui.dp(20), ui.dp(14))
            // On the time, not the row: a row with a description hides its texts from TalkBack.
            (row.getChildAt(0) as TextView).apply {
                text = Languages.clock(l.t)
                contentDescription = if (playable) "${L("从这里播放")} ${text}" else null
                setTextColor(when { now -> Palette.accent; playable -> Palette.link; else -> Palette.tertiary })
                typeface = if (now) android.graphics.Typeface.DEFAULT_BOLD else android.graphics.Typeface.DEFAULT
            }
            (row.getChildAt(2) as PlayingBars).on = now && playingOn
            val texts = row.getChildAt(1) as LinearLayout
            val name = SpeakerLabels.speakerName(l, numbers, names)
            (texts.getChildAt(0) as TextView).apply {
                text = name
                visibility = if (who) View.VISIBLE else View.GONE
                setTextColor(if (l.speaker == "me") Palette.ink else NotesViews.voiceColor(numbers[l.id]).second.takeIf { numbers[l.id] != null } ?: Palette.secondary)
            }
            val translated = !l.dst.isNullOrEmpty() && l.dst != l.shown
            val current = l.id == currentMatch()
            (texts.getChildAt(1) as TextView).apply { text = marked(FixViews.text(ui, l), current); visibility = if (translated) View.VISIBLE else View.GONE }
            (texts.getChildAt(2) as TextView).text = marked(if (translated) l.dst!! else FixViews.text(ui, l), current)
            return row
        }
    }

    /// Three bars that bounce beside the line the recording is playing; nothing while paused
    /// (still bars when the system's animations are off).
    private inner class PlayingBars : View(this@RecordActivity) {
        var on = false; set(v) { if (field != v) { field = v; invalidate() } }
        private val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { color = Palette.accent }

        override fun onDraw(c: android.graphics.Canvas) {
            if (!on) return
            val moving = android.animation.ValueAnimator.areAnimatorsEnabled()
            val t = android.os.SystemClock.uptimeMillis() / 1000.0
            val w = ui.dp(3).toFloat(); val gap = ui.dp(2).toFloat(); val r = w / 2
            for (i in 0 until 3) {
                val h = height * (if (moving) 0.35 + 0.65 * Math.abs(Math.sin(t * 3.5 + i * 0.9)) else 0.7).toFloat()
                val x = i * (w + gap)
                c.drawRoundRect(x, height - h, x + w, height.toFloat(), r, r, paint)
            }
            if (moving) postInvalidateOnAnimation()
        }
    }

    override fun onSaveInstanceState(out: Bundle) { super.onSaveInstanceState(out); out.putInt("tab", tab); out.putInt("match", matchIndex) }

    // MARK: The recording (保存会议录音)

    /// The floating player (iOS's PlayerBar on a white card): play / pause, the progress line
    /// (drag it to seek), the time and the length under it, and the speed.
    private fun buildPlayer() {
        val play = android.widget.ImageView(this).apply { setImageDrawable(ui.drawable(R.drawable.i_play, android.graphics.Color.WHITE)); importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }
        val button = FrameLayout(this).apply {
            contentDescription = L("播放")
            addView(play, FrameLayout.LayoutParams(ui.dp(20), ui.dp(20), android.view.Gravity.CENTER))
            ui.tappable(this, 24, ui.rounded(Palette.ink, 24), dark = true) { toggle() }
        }
        val scrub = Scrubber()
        val time = ui.text("00:00", 11f, Palette.secondary).apply { fontFeatureSettings = "tnum" }
        val length = ui.text("00:00", 11f, Palette.secondary).apply { fontFeatureSettings = "tnum"; gravity = android.view.Gravity.END }
        val times = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(time, ui.weight()); addView(length, LinearLayout.LayoutParams(-2, -2))
        }
        val speedText = ui.text("1×", 13f, Palette.ink, bold = true, lines = 1).apply { fontFeatureSettings = "tnum"; gravity = android.view.Gravity.CENTER }
        val speedButton = FrameLayout(this).apply {
            contentDescription = L("播放速度")
            addView(speedText, FrameLayout.LayoutParams(-1, -1))
            ui.tappable(this, 24) { cycleSpeed() }
        }
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = android.view.Gravity.CENTER_VERTICAL
            // On the white page a shadow alone doesn't separate it: a hairline too.
            background = ui.rounded(Palette.card, 32, Palette.line, 1)
            ui.lift(this, 6)
            setPadding(ui.dp(8), ui.dp(4), ui.dp(4), ui.dp(4))
            addView(button, LinearLayout.LayoutParams(ui.dp(48), ui.dp(48)))
            // The line's touch area is taller than the line (scrub.height), the times tucked under it.
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                addView(scrub, LinearLayout.LayoutParams(-1, ui.dp(24)))
                addView(times, LinearLayout.LayoutParams(-1, -2).apply { topMargin = -ui.dp(4) })
            }, ui.weight().apply { leftMargin = ui.dp(14) })
            addView(speedButton, LinearLayout.LayoutParams(ui.dp(52), ui.dp(48)).apply { leftMargin = ui.dp(4) })
        }
        playButton = play; playFrame = button; playTime = time; playLength = length; speedLabel = speedText; scrubber = scrub
        playerHost.addView(LinearLayout(this).apply {
            background = ui.fade(Palette.card)
            setPadding(ui.dp(16), ui.dp(28), ui.dp(16), ui.dp(16))
            addView(card, LinearLayout.LayoutParams(-1, ui.dp(64)))
        })
    }

    /// The progress line: the track grey, what has played in the accent; a tap or a drag seeks.
    private inner class Scrubber : View(this@RecordActivity) {
        var fraction = 0f; set(v) { field = v; invalidate() }
        var dragging = false; private set
        private val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)

        override fun onDraw(c: android.graphics.Canvas) {
            val r = ui.dp(2).toFloat()
            val y = height / 2f
            val x = width * fraction
            paint.color = TRACK
            c.drawRoundRect(0f, y - r, width.toFloat(), y + r, r, r, paint)
            paint.color = Palette.accent
            if (x > 0) c.drawRoundRect(0f, y - r, maxOf(x, 2 * r), y + r, r, r, paint)
            if (dragging) c.drawCircle(x, y, ui.dp(7).toFloat(), paint)
        }

        override fun onTouchEvent(e: android.view.MotionEvent): Boolean {
            val f = if (width > 0) (e.x / width).coerceIn(0f, 1f) else 0f
            when (e.actionMasked) {
                android.view.MotionEvent.ACTION_DOWN -> { parent.requestDisallowInterceptTouchEvent(true); dragging = true; fraction = f; showTime() }
                android.view.MotionEvent.ACTION_MOVE -> { fraction = f; showTime() }
                android.view.MotionEvent.ACTION_UP -> { dragging = false; fraction = f; seekFraction(f) }
                android.view.MotionEvent.ACTION_CANCEL -> { dragging = false; updatePlayer() }
            }
            return true
        }

        // While dragging the time follows the finger; the player moves on release.
        private fun showTime() { playTime?.text = Languages.clock(fraction * length()) }
    }

    private fun length() = (player?.duration ?: 0).takeIf { it > 0 }?.div(1000.0) ?: 0.0

    private fun ensurePlayer(): android.media.MediaPlayer? {
        player?.let { return it }
        return try {
            android.media.MediaPlayer().apply {
                setAudioAttributes(android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                    .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH).build())
                setDataSource(audio().path); prepare()
                setOnCompletionListener { updatePlayer() }
            }.also { player = it }
        } catch (e: Exception) { Log.d("record: play failed ${e.javaClass.simpleName}"); null }
    }

    private fun releasePlayer() {
        list.removeCallbacks(tickPlayer)
        player?.release(); player = null
        playing = null; playingOn = false
        following = true
        if (::backToPlaying.isInitialized) backToPlaying.visibility = View.GONE
    }

    private fun start(p: android.media.MediaPlayer) {
        p.start()
        // Setting the speed on a paused player starts it on some versions: only ever while playing.
        if (speed != 1f) try { p.playbackParams = p.playbackParams.setSpeed(speed) } catch (_: Exception) {}
        list.removeCallbacks(tickPlayer); list.post(tickPlayer)
    }

    private fun toggle() {
        val p = ensurePlayer() ?: return
        if (p.isPlaying) p.pause() else start(p)
        updatePlayer()
    }

    /// A line's time (or the line): plays the recording from where it was said.
    private fun playFrom(t: Double) {
        if (playerHost.visibility != View.VISIBLE) return
        val p = ensurePlayer() ?: return
        p.seekTo((t * 1000).toLong().coerceAtLeast(0), android.media.MediaPlayer.SEEK_CLOSEST)
        if (!p.isPlaying) start(p)
        updatePlayer()
        follow()
    }

    private fun seekFraction(f: Float) {
        val p = ensurePlayer() ?: return
        p.seekTo((f * p.duration).toLong(), android.media.MediaPlayer.SEEK_CLOSEST)
        updatePlayer()
        follow()
    }

    /// 1× → 1.5× → 2× → 1×.
    private fun cycleSpeed() {
        speed = when (speed) { 1f -> 1.5f; 1.5f -> 2f; else -> 1f }
        speedLabel?.text = if (speed == 1.5f) "1.5×" else "${speed.toInt()}×"
        val p = player
        if (p?.isPlaying == true) try { p.playbackParams = p.playbackParams.setSpeed(speed) } catch (_: Exception) {}
    }

    private fun updatePlayer() {
        val p = player
        val on = p?.isPlaying == true
        val pos = (p?.currentPosition ?: 0) / 1000.0
        val dur = length()
        playButton?.setImageDrawable(ui.drawable(if (on) R.drawable.i_pause else R.drawable.i_play, android.graphics.Color.WHITE))
        playFrame?.contentDescription = if (on) L("暂停") else L("播放")
        if (scrubber?.dragging != true) {
            playTime?.text = Languages.clock(pos)
            scrubber?.fraction = if (dur > 0) (pos / dur).toFloat().coerceIn(0f, 1f) else 0f
        }
        playLength?.text = Languages.clock(dur)
        // The line being heard: the last one that started at or before the playhead, once
        // playing has begun (iOS's lineID).
        val lines = if (p != null && (on || pos > 0)) cicada.store.get(id)?.lines.orEmpty() else emptyList()
        val line = lines.lastOrNull { it.t <= pos + 0.2 }
        val now = line?.id
        backToPlayingText.text = line?.let { "${L("回到正在播放")} · ${Languages.clock(it.t)}" } ?: ""
        if (line == null) backToPlaying.visibility = View.GONE
        if (now == playing && on == playingOn) return
        val moved = now != playing
        playing = now; playingOn = on
        adapter.notifyDataSetChanged()
        if (on && moved && following) centre(adapter.indexOf(now))
    }

    /// Back to following the recording: the 回到正在播放 capsule, a tapped line, the bar.
    private fun follow() {
        backToPlaying.visibility = View.GONE
        if (following) return
        following = true
        centre(adapter.indexOf(playing))
    }

    private fun showBackToPlaying() {
        if (playing == null) return
        backToPlaying.alpha = 0f; backToPlaying.translationY = ui.dp(8).toFloat()
        backToPlaying.visibility = View.VISIBLE
        backToPlaying.animate().alpha(1f).translationY(0f).setDuration(200).start()
    }

    /// Scrolls the line being heard to the middle of what shows between the pinned tabs and the
    /// player (the Mac's anchor: .center): smoothly when it is on screen, a jump from far away.
    private fun centre(index: Int) {
        if (index < 0) return
        val pos = index + list.headerViewsCount
        val top = (if (pinnedTabs.visibility == View.VISIBLE) pinnedTabs.height else 0) + (if (matchBar.visibility == View.VISIBLE) matchBar.height else 0)
        val bottom = list.height - (if (playerHost.visibility == View.VISIBLE) playerHost.height else 0)
        val row = list.getChildAt(pos - list.firstVisiblePosition)
        val y = top + maxOf(0, (bottom - top - (row?.height ?: ui.dp(96))) / 2)
        if (row != null) list.smoothScrollBy(row.top - y, 300) else list.setSelectionFromTop(pos, y)
    }

    /// For `cicadactl state`: the open record's player (never what was said).
    fun debugState(): Map<String, Any?> {
        val p = player
        return mapOf("id" to id, "tab" to tab, "playable" to (playerHost.visibility == View.VISIBLE), "playing" to (p?.isPlaying == true),
                     "position" to ((p?.currentPosition ?: 0) / 1000.0), "line" to playing, "lineIndex" to adapter.indexOf(playing),
                     "following" to following, "backToPlaying" to (backToPlaying.visibility == View.VISIBLE),
                     "firstVisible" to (list.firstVisiblePosition - list.headerViewsCount), "lastVisible" to (list.lastVisiblePosition - list.headerViewsCount),
                     // Opened from a search: lines found, the one looked at (1-based), its id and row (never the words).
                     "search" to if (query.isEmpty()) null else mapOf("matches" to found.size, "at" to (if (found.isEmpty()) 0 else matchIndex + 1),
                         "line" to currentMatch(), "lineIndex" to adapter.indexOf(currentMatch()), "bar" to (matchBar.visibility == View.VISIBLE)))
    }

    // MARK: 更多: export and the rest

    private fun more() {
        val s = cicada.store.get(id) ?: return
        lateinit var d: android.app.Dialog
        fun act(res: Int, label: String, helper: String? = null, red: Boolean = false, run: () -> Unit) = ui.sheetAction(res, label, helper, red) { d.dismiss(); run() }
        // 分享…: a link on cicada.indaloop.app (the round 分享 above sends the Markdown).
        val link = act(R.drawable.i_external, L("分享…"), L("生成链接")) { ShareSheet(this, ui, s.id).show() }
        if (!ShareSheet.canShare(cicada, s)) { link.alpha = 0.4f; link.isEnabled = false; link.isClickable = false }
        val box = ui.stack(0, link,
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

    companion object {
        /// The record in front, for the debug state.
        var current: RecordActivity? = null; private set
        /// The line being heard (the Mac's Palette.accentPale) and the player's unplayed track.
        private val PLAYING_LINE = android.graphics.Color.parseColor("#FCEDE7")
        private val TRACK = android.graphics.Color.parseColor("#E1E3E8")
    }
}
