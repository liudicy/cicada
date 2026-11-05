package com.wquguru.cicada

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import cicada.Languages
import cicada.Session
import cicada.SessionStore
import cicada.Strings.L
import cicada.Strings.LF
import cicada.UpdateChecker
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/// 首页 is 会议记录 (as on iOS): the large title, the card that starts listening (what the phone
/// plays, or 面对面) or shows the meeting going on, then the meetings by day. 会议记录 / 设置 and
/// search float at the bottom; 导入 is the round button by the title.
class MainActivity : Activity() {
    private lateinit var ui: Ui
    private lateinit var top: FrameLayout
    private lateinit var recent: FrameLayout
    private var shownTop: String? = null
    private var shownRecent: String? = null
    private var clockText: TextView? = null
    private var unobserve: (() -> Unit)? = null
    private val tick = object : Runnable {
        override fun run() { clockText?.text = NotesViews.status(cicada); renderTop(); cicada.main.postDelayed(this, 1000) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ui = Ui(this)
        if (!cicada.settings.onboarded) startActivity(Intent(this, OnboardingActivity::class.java))
        top = FrameLayout(this); recent = FrameLayout(this)
        val body = ui.stack(8, top, recent).apply { setPadding(ui.dp(16), ui.dp(8), ui.dp(16), ui.dp(24)) }
        builtTitle = L("会议记录")
        setContentView(ui.screen(this, builtTitle, back = false, ground = Palette.ground, body = body, bottom = ui.nav(this, "records"),
            actions = listOf(ui.roundButton(R.drawable.i_import, L("导入录音或视频")) { startActivity(Intent(this, ImportActivity::class.java)) })))
    }

    private var builtTitle = ""

    override fun onResume() {
        super.onResume()
        // The nav brings this screen back to the front rather than making a new one, so a language
        // changed in 设置 meanwhile would leave the title and nav in the old one.
        if (L("会议记录") != builtTitle) { recreate(); return }
        unobserve = cicada.observe(::render)
        shownTop = null; shownRecent = null
        render()
        cicada.updates.checkIfDue(UpdateChecker.STALE)
        cicada.main.postDelayed(tick, 1000)
    }

    override fun onPause() {
        super.onPause()
        unobserve?.invoke(); unobserve = null
        cicada.main.removeCallbacks(tick)
    }

    private fun render() { renderTop(); renderRecent() }

    private val micDenied get() = checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED

    private fun renderTop() {
        val app = cicada
        val file = app.importing
        val key = listOf(NotesViews.liveKey(app), app.autoEnded, app.settings.source, app.settings.target, app.canOverlay, app.settings.overlay, micDenied, app.listen.spoken,
                         app.startProblem, file?.done?.toInt(), app.updates.available?.version).joinToString("|")
        if (key == shownTop) return
        shownTop = key
        top.removeAllViews()
        val column = ui.stack(12)
        column.addView(when {
            file != null -> importCard(file)
            app.listen.listening -> liveCard()
            else -> startCard()
        })
        if (app.settings.overlay && !app.canOverlay && file == null) column.addView(tipCard())
        // A new version, under the start card; never while a meeting or a file is going on.
        app.updates.available?.takeIf { file == null && !app.listen.listening }?.let { column.addView(updateCard(it)) }
        top.addView(column)
    }

    /// A meeting is going on: where it is and a way back to it.
    private fun liveCard(): LinearLayout {
        val app = cicada
        val status = ui.text(NotesViews.status(app), 15f, Palette.link, bold = true)
        clockText = status
        val card = ui.card(ui.row(8, ui.dot(Palette.accent), status), gap = 12)
        card.addView(ui.helper(NotesViews.sourceLine(app)), ui.lp(top = 4))
        NotesViews.currentLines(app).lastOrNull()?.let { l -> card.addView(ui.text(l.dst ?: l.src, 18f, Palette.ink, bold = true, lines = 3).apply { leading(1.4f) }, ui.lp(top = 12)) }
        card.addView(ui.button(L("回到正在听"), "primary", R.drawable.i_waves) { app.openLive() }, ui.lp(top = 16))
        return card
    }

    /// A file being transcribed: its name and how far it is.
    private fun importCard(file: FileSource): LinearLayout {
        clockText = null
        val app = cicada
        val name = app.listen.sessionId?.let { app.store.get(it) }?.sourceFile ?: ""
        val card = ui.card(gap = 10)
        card.addView(ui.row(8, ui.dot(Palette.accent), ui.text(L("正在转写"), 15f, Palette.link, bold = true), ui.text(name, 15f, Palette.ink, lines = 1).apply { layoutParams = ui.weight() }))
        card.addView(NotesViews.progress(ui, file), ui.lp(top = 6))
        card.addView(ui.button(L("查看进度"), "quiet") { startActivity(Intent(this, ImportActivity::class.java)) }, ui.lp(top = 10))
        return card
    }

    private fun startCard(): LinearLayout {
        val app = cicada
        val pb = app.settings.source != "mic"
        clockText = null
        val card = ui.card(gap = 16)
        // The last meeting ended by itself (as the Mac's menu says 会议已自动结束, not 已暂停).
        if (app.autoEnded) card.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(ui.dot(Palette.outline, 8))
            addView(ui.text(L("会议已自动结束"), 15f, Palette.ink, bold = true), ui.weight().apply { leftMargin = ui.dp(10) })
            app.listen.sessionId?.takeIf { app.store.get(it) != null }?.let { id ->
                addView(ui.textButton(L("查看纪要")) { startActivity(Intent(this@MainActivity, RecordActivity::class.java).putExtra("id", id)) })
            }
        }, ui.lp(top = 0).apply { bottomMargin = ui.dp(12) })
        card.addView(ui.segmented(listOf("playback" to L("手机里的声音"), "mic" to L("面对面")), app.settings.source) {
            app.settings.source = it; app.saveSettings(); shownTop = null; renderTop()
        })
        val desc = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(ui.logo(44))
            addView(ui.stack(2,
                ui.text(if (pb) L("视频、直播、网课里的声音") else L("用麦克风听身边的人"), 17f, Palette.ink, bold = true),
                ui.helper(if (pb) L("通话和会议 app 的声音系统不让录，改用“面对面”") else L("线下开会，或会议 app 开外放"))), ui.weight().apply { leftMargin = ui.dp(12) })
        }
        card.addView(desc, ui.lp(top = 16))
        // The language pair: what is heard (found by itself) → what subtitles read in.
        val lang = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            minimumHeight = ui.dp(44)
            setPadding(ui.dp(16), 0, ui.dp(12), 0)
            addView(ui.text(L("自动识别"), 15f, Palette.secondary))
            addView(ui.icon(R.drawable.i_arrow_right, 16, Palette.secondary), LinearLayout.LayoutParams(ui.dp(16), ui.dp(16)).apply { leftMargin = ui.dp(8); rightMargin = ui.dp(8) })
            addView(ui.text(NotesViews.languageName(app.settings.targetCode), 15f, Palette.ink, medium = true))
            addView(ui.icon(R.drawable.i_chevron_down, 18, Palette.tertiary), LinearLayout.LayoutParams(ui.dp(18), ui.dp(18)).apply { leftMargin = ui.dp(6) })
            contentDescription = L("翻译成") + " " + NotesViews.languageName(app.settings.targetCode)
            ui.tappable(this, 22, ui.rounded(Palette.ground, 22)) { chooseTarget() }
        }
        card.addView(lang, ui.lp(top = 16))
        app.startProblem?.let { card.addView(ui.text(it, 14f, Palette.link).apply { accessibilityLiveRegion = 1 }, ui.lp(top = 16)) }
        if (micDenied && app.startProblem != null)
            card.addView(ui.textButton(L("去系统设置开启麦克风权限")) {
                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
            }.apply { gravity = Gravity.START or Gravity.CENTER_VERTICAL; setPadding(ui.dp(4), 0, ui.dp(4), 0) }, ui.lp(top = 4, width = -2))
        card.addView(ui.button(L("开始听"), "primary", R.drawable.i_waves) { app.startListening(this, app.settings.source) }, ui.lp(top = 16))
        return card
    }

    private fun tipCard() = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = ui.rounded(Palette.card, 22)
        setPadding(ui.dp(16), ui.dp(12), ui.dp(8), ui.dp(12))
        addView(ui.tile(R.drawable.i_pip, 40, Palette.accentPale, Palette.link).apply { background = ui.rounded(Palette.accentPale, 20) })
        addView(ui.stack(2, ui.text(L("在视频上直接看字幕"), 15f, Palette.ink, medium = true), ui.helper(L("开启“显示在其他应用上层”"))),
                ui.weight().apply { leftMargin = ui.dp(12) })
        addView(ui.textButton(L("去开启")) { OverlayGuideActivity.open(this@MainActivity, direct = true) })
    }

    /// 有新版本: 更新 downloads the APK in the browser, the words open the release notes.
    private fun updateCard(u: UpdateChecker.Update) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = ui.rounded(Palette.card, 22)
        setPadding(ui.dp(16), ui.dp(12), ui.dp(8), ui.dp(12))
        addView(ui.tile(R.drawable.i_update, 40, Palette.accentPale, Palette.link).apply { background = ui.rounded(Palette.accentPale, 20) })
        // The words open the release notes (a bigger target than the grey line alone).
        val texts = ui.stack(2, ui.text(LF("有新版本 %@", u.version), 15f, Palette.ink, medium = true), ui.helper(L("更新说明"))).apply {
            setPadding(ui.dp(6), ui.dp(4), ui.dp(6), ui.dp(4))
            contentDescription = LF("有新版本 %@", u.version) + "，" + L("更新说明")
            ui.tappable(this, 12) { cicada.updates.openNotes() }
        }
        addView(texts, ui.weight().apply { leftMargin = ui.dp(6) })
        addView(ui.textButton(L("更新")) { cicada.updates.download() })
    }

    /// The meetings, newest first, under 今天 / 昨天 / the date (the last 60; search finds the rest).
    private fun renderRecent() {
        val app = cicada
        val sessions = app.store.all().take(60)
        val liveId = if (app.listen.listening) app.listen.sessionId else null
        val key = sessions.joinToString { "${it.id}:${SessionStore.displayTitle(it)}:${it.lines.size}:${it.endedAt}:${it.notes?.todos?.size}" } + liveId + app.store.loaded
        if (key == shownRecent) return
        shownRecent = key
        recent.removeAllViews()
        val column = ui.stack(0)
        if (sessions.isEmpty() && !app.store.loaded) column.addView(android.widget.ProgressBar(this).apply { isIndeterminate = true; contentDescription = L("正在加载…") }, ui.lp(top = 16, width = ui.dp(32), height = ui.dp(32)))
        else if (sessions.isEmpty()) column.addView(ui.helper(L("还没有会议记录")).apply { setPadding(ui.dp(16), ui.dp(20), 0, 0) })
        val days = LinkedHashMap<String, MutableList<Session>>()
        for (s in sessions) days.getOrPut(day(s.startedAt)) { mutableListOf() }.add(s)
        for ((d, items) in days) {
            column.addView(ui.sectionLabel(d))
            column.addView(ui.group(items.map { recordRow(this, ui, it, it.id == liveId) }))
        }
        recent.addView(column)
    }

    private fun chooseTarget() {
        val app = cicada
        val options = listOf("system" to L("跟随系统")) + Languages.targets.map { it.code to it.name }
        ui.choose(this, L("翻译成"), options, app.settings.target) { app.settings.target = it; app.saveSettings(); shownTop = null; renderTop() }
    }

    companion object {
        /// "今天 20:54" / "昨天 09:02" / "11月1日 15:30".
        fun day(at: Instant): String {
            val local = at.atZone(ZoneId.systemDefault())
            val d = local.toLocalDate()
            val today = LocalDate.now()
            val label = when (d) {
                today -> L("今天")
                today.minusDays(1) -> L("昨天")
                else -> DateTimeFormatter.ofPattern(L("M月d日"), cicada.Strings.locale).format(local)
            }
            return label
        }

        fun time(at: Instant): String = DateTimeFormatter.ofPattern("HH:mm").withZone(ZoneId.systemDefault()).format(at)

        /// The meeting's name without its date (lists and rename show the date apart).
        fun name(s: Session): String =
            if (s.renamed ?: !s.title.startsWith("会议 ")) s.title else s.notes?.title?.takeIf { it.isNotEmpty() } ?: SessionStore.displayTitle(s)

        /// One meeting in a list: title (and 正在听), when, how long, how many lines, to-dos.
        fun recordRow(activity: Activity, ui: Ui, s: Session, live: Boolean): LinearLayout {
            // The line under it says when: the title is just the meeting's name.
            val title = name(s)
            val titleView = LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                if (live) addView(ui.badge(if (activity.cicada.importing != null) L("正在转写") else L("正在听"), dot = true), LinearLayout.LayoutParams(-2, -2).apply { rightMargin = ui.dp(8) })
                addView(ui.text(title, 16f, Palette.ink, bold = true, lines = 1), ui.weight())
            }
            // Under a day's heading: the time, how long, how many lines, and where it came from.
            val from = s.sourceFile?.let { L("导入") }
            val meta = if (live) "${time(s.startedAt)} · ${Languages.clock(s.durationSeconds)}"
                       else listOfNotNull("${time(s.startedAt)}", Languages.clock(s.durationSeconds), "${s.lines.size} ${L("句")}", from).joinToString(" · ")
            val todos = s.notes?.todos?.size ?: 0
            val trailing = if (todos > 0) ui.badge(LF("%@ 个待办", todos), Palette.body, Palette.ground) else null
            return ui.listRow(title, meta, trailing = trailing, titleView = titleView) {
                activity.startActivity(Intent(activity, if (live) ListeningActivity::class.java else RecordActivity::class.java).putExtra("id", s.id))
            }
        }
    }
}
