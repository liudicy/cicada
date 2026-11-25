package com.wquguru.cicada

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.text.SpannableString
import android.text.style.StyleSpan
import android.view.Gravity
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import cicada.Strings.L
import cicada.Strings.LF
import cicada.Vocabulary

/// 设置 › 词表 (the Mac's WordListSettings.swift): the two switches of 改正听错的词, and the word list
/// itself: each word (tap to change its spelling), what it has been heard as (× takes one off, +
/// adds one), where it came from and how often it fixed a line. A deleted word comes back with
/// 撤销; 粘贴导入… takes many at once and says what it will do first.
class WordListActivity : Activity() {
    private lateinit var ui: Ui
    private lateinit var page: LinearLayout
    private var unobserve: (() -> Unit)? = null
    private var shown: String? = null
    private var query = ""
    private var search: EditText? = null
    /// A deleted word, shown in its place with 撤销 for a few seconds.
    private var deleted: Pair<Vocabulary.Term, Int>? = null
    private var deletedAt = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ui = Ui(this)
        page = ui.stack(0).apply { setPadding(ui.dp(16), ui.dp(4), ui.dp(16), ui.dp(32)) }
        setContentView(ui.screen(this, L("词表"), back = true, ground = Palette.ground, body = page))
    }

    override fun onResume() { super.onResume(); unobserve = cicada.observe(::build); shown = null; build() }
    override fun onPause() { super.onPause(); unobserve?.invoke(); unobserve = null }

    private fun build() {
        val app = cicada
        val s = app.settings
        val terms = app.vocabulary.terms
        val key = listOf(terms, s.fixMisheard, s.askNames, app.ling.usable, app.ling.provider.id, deleted?.first?.word, query).joinToString("|")
        if (key == shown) return
        shown = key
        page.removeAllViews()

        // The switches; without an AI service the first gives way to a way to set one up.
        val usable = app.ling.usable
        val fixRow = if (usable) ui.switchRow(L("会中改正听错的词"), LF("走 %@，只发文字", AiServiceActivity.name(app.ling.provider)), s.fixMisheard) {
            s.fixMisheard = it; app.saveSettings()
        } else ui.listRow(L("会中改正听错的词"), L("接上 AI 服务后才会改"), trailing = ui.text(L("去设置"), 15f, Palette.link, bold = true), chevron = false) {
            startActivity(Intent(this, AiServiceActivity::class.java))
        }
        val askRow = ui.switchRow(L("没见过的名字和专称先问我"), L("关掉就只改词表里的词和同音错字"), s.askNames) { s.askNames = it; app.saveSettings() }
        if (!s.fixMisheard || !usable) { askRow.alpha = 0.45f; askRow.isEnabled = false; disable(askRow) }
        page.addView(ui.group(listOf(fixRow, askRow)), ui.lp(top = 8))

        // 词 · N, and 粘贴导入….
        page.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(ui.dp(4), ui.dp(22), 0, ui.dp(8))
            addView(ui.text(L("词"), 15f, Palette.secondary, bold = true))
            if (terms.isNotEmpty()) addView(ui.text("${terms.size}", 14f, Palette.tertiary).apply { fontFeatureSettings = "tnum" }, LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(8) })
            addView(ui.spacer())
            addView(ui.button(L("粘贴导入…"), "primary", height = 40) { importSheet() })
        })
        if (terms.size > 12) {
            val field = search ?: EditText(this).apply {
                hint = L("搜索词表"); setSingleLine(); textSize = 15f
                background = ui.rounded(Palette.card, 14); setPadding(ui.dp(14), 0, ui.dp(14), 0); minHeight = ui.dp(44)
                addTextChangedListener(object : android.text.TextWatcher {
                    override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                    override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                    override fun afterTextChanged(e: android.text.Editable?) { query = e.toString(); build() }
                })
            }.also { search = it }
            (field.parent as? android.view.ViewGroup)?.removeView(field)
            page.addView(field, ui.lp().apply { bottomMargin = ui.dp(10) })
        }

        val d = deleted?.takeIf { System.currentTimeMillis() - deletedAt < 8000 }
        if (terms.isEmpty() && d == null) {
            page.addView(ui.helper(L("还没有词。把常用的人名、产品名贴进来，会中就照这些写法改"), Palette.tertiary).apply { setPadding(ui.dp(4), ui.dp(6), ui.dp(4), ui.dp(6)) })
        } else {
            val rows = mutableListOf<View>()
            if (d != null) rows.add(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                minimumHeight = ui.dp(52)
                setPadding(ui.dp(16), 0, ui.dp(4), 0)
                val t = SpannableString(L("已删除") + " " + d.first.word)
                t.setSpan(StyleSpan(android.graphics.Typeface.BOLD), t.length - d.first.word.length, t.length, 0)
                addView(ui.text(t, 15f, Palette.secondary, lines = 1), ui.weight())
                addView(ui.textButton(L("撤销")) { app.vocabulary.insert(d.first, d.second); deleted = null; build() })
            })
            for (t in shownTerms(terms)) rows.add(wordRow(t))
            page.addView(ui.group(rows))
        }
        page.addView(ui.helper(LF("最多 %lld 个，满了优先用最近的。只存在这台手机上", Vocabulary.LIMIT), Palette.tertiary).apply { setPadding(ui.dp(4), ui.dp(12), ui.dp(4), 0) })
    }

    private fun disable(v: View) {
        v.isClickable = false
        v.setOnClickListener(null)
    }

    /// Most recently useful first, then the rest newest first; the search keeps words or heard forms that match.
    private fun shownTerms(terms: List<Vocabulary.Term>): List<Vocabulary.Term> {
        val all = terms.reversed().sortedByDescending { it.used ?: java.time.Instant.EPOCH }
        val q = Vocabulary.key(query)
        if (q.isEmpty()) return all
        return all.filter { t -> Vocabulary.key(t.word).contains(q) || t.heard.any { Vocabulary.key(it).contains(q) } }
    }

    private fun wordRow(t: Vocabulary.Term): View {
        val app = cicada
        val v = app.vocabulary
        val row = ui.stack(8)
        row.setPadding(ui.dp(16), ui.dp(12), ui.dp(4), ui.dp(12))
        row.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            // The word: a tap changes its spelling; what it was heard as stays with it.
            addView(ui.text(t.word, 17f, Palette.ink, bold = true, lines = 1).apply {
                contentDescription = "${t.word}，${L("点一下改写法")}"
                minHeight = ui.dp(40); gravity = Gravity.CENTER_VERTICAL
                ui.tappable(this, 8) { ui.input(this@WordListActivity, L("词表"), t.word, helper = L("点一下改写法")) { v.rename(t.word, it) } }
            }, ui.weight())
            addView(ui.iconButton(R.drawable.i_trash, L("从词表里删掉"), Palette.tertiary, 20) { remove(t) })
        })
        // What it has been heard as: × takes one off; + adds one (asking whose it is when another word has it).
        val chips = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        var line = LinearLayout(this)
        var used = 0
        val width = resources.displayMetrics.widthPixels - ui.dp(80)
        fun place(chip: View) {
            chip.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED)
            val w = chip.measuredWidth + ui.dp(6)
            if (line.childCount > 0 && used + w > width) { chips.addView(line); line = LinearLayout(this); used = 0 }
            line.addView(chip, LinearLayout.LayoutParams(-2, -2).apply { rightMargin = ui.dp(6); bottomMargin = ui.dp(6) })
            used += w
        }
        for (h in t.heard) place(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = ui.rounded(Palette.ground, 8)
            setPadding(ui.dp(10), 0, 0, 0)
            addView(ui.text(h, 14f, Palette.secondary, lines = 1))
            addView(ui.iconButton(R.drawable.i_close, L("删掉这个听错的词"), Palette.tertiary, 14) { v.forget(h, t.word) }, LinearLayout.LayoutParams(ui.dp(36), ui.dp(36)))
        })
        place(ui.text("+ " + L("加一个容易听错的词"), 13f, Palette.link, lines = 1).apply {
            gravity = Gravity.CENTER_VERTICAL
            minHeight = ui.dp(36)
            setPadding(ui.dp(10), 0, ui.dp(10), 0)
            background = ui.rounded(Palette.card, 8, Palette.outline, 1)
            ui.tappable(this, 8, background) { addHeard(t) }
        })
        if (line.childCount > 0) chips.addView(line)
        row.addView(chips)
        val live = t.source == "live"
        val meta = SpannableString((if (live) L("会中确认") else L("你加的")) + " · " + (if (t.fixes > 0) LF("改过 %lld 次", t.fixes) else L("还没用上")))
        if (live) meta.setSpan(android.text.style.ForegroundColorSpan(Palette.link), 0, L("会中确认").length, 0)
        row.addView(ui.text(meta, 13f, Palette.tertiary))
        return row
    }

    private fun addHeard(t: Vocabulary.Term) {
        val v = cicada.vocabulary
        ui.input(this, L("加一个容易听错的词"), "") { raw ->
            val h = raw.trim()
            if (h.isEmpty() || h.length > 40) return@input
            val owner = v.owners(h, t.word).firstOrNull()
            if (owner == null) { v.confirm(h, t.word, t.source); return@input }
            // Already another word's: whose should it be? Both kept is asked about each time, never fixed silently.
            lateinit var d: android.app.Dialog
            val body = ui.stack(10,
                ui.button(LF("改给 %@", t.word), "primary") { d.dismiss(); v.forget(h, owner); v.confirm(h, t.word, t.source) },
                ui.button(L("两个都留"), "quiet") { d.dismiss(); v.confirm(h, t.word, t.source) })
            d = ui.sheet(this, LF("“%@”已经记在 %@ 下", h, owner), body)
            d.show()
        }
    }

    private fun remove(t: Vocabulary.Term) {
        val v = cicada.vocabulary
        val index = v.terms.indexOf(t).coerceAtLeast(0)
        v.remove(t.word)
        deleted = t to index
        deletedAt = System.currentTimeMillis()
        page.postDelayed({ if (System.currentTimeMillis() - deletedAt >= 8000) { deleted = null; shown = null; build() } }, 8100)
        shown = null
        build()
    }

    /// 粘贴导入: one per line, heard forms after "="; the counts follow what is pasted, and the
    /// button says how many go in.
    private fun importSheet() {
        val v = cicada.vocabulary
        lateinit var d: android.app.Dialog
        val field = EditText(this).apply {
            hint = "Uniswap V3\nMorpho = 莫拉、莫法\n巡检"
            textSize = 15f
            gravity = Gravity.TOP
            minLines = 5; maxLines = 9
            background = ui.rounded(Palette.ground, 16)
            setPadding(ui.dp(14), ui.dp(12), ui.dp(14), ui.dp(12))
        }
        val counts = ui.text("", 13f, Palette.secondary)
        val result = ui.text("", 13f, Palette.link).apply { visibility = View.GONE }
        lateinit var go: LinearLayout
        val buttons = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        fun update() {
            val text = field.text.toString()
            val p = v.preview(text)
            counts.text = if (text.isBlank()) "" else LF("新增 %lld · 补充听成 %lld · 跳过 %lld", p.added, p.updated, p.skipped.size)
            val n = p.added + p.updated
            (go.getChildAt(0) as android.widget.TextView).text = LF("导入 %lld 个", n)
            go.isEnabled = n > 0; go.alpha = if (n > 0) 1f else 0.4f
        }
        go = ui.button(LF("导入 %lld 个", 0), "primary") {
            val r = v.importText(field.text.toString())
            field.setText(""); field.isEnabled = false
            counts.text = LF("新增 %lld · 补充听成 %lld · 跳过 %lld", r.added, r.updated, r.skipped.size)
            counts.setTextColor(Palette.ink)
            if (r.skipped.isNotEmpty()) { result.text = LF("第 %@ 行没加进去：超过 40 个字", r.skipped.joinToString("、")); result.visibility = View.VISIBLE }
            buttons.removeAllViews()
            buttons.addView(ui.button(L("完成"), "primary") { d.dismiss() }, ui.weight())
        }
        field.addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(e: android.text.Editable?) { if (field.isEnabled) update() }
        })
        buttons.addView(ui.button(L("取消"), "quiet") { d.dismiss() }, ui.weight())
        buttons.addView(go, ui.weight().apply { leftMargin = ui.dp(10) })
        update()
        val body = ui.stack(10, ui.helper(L("一行一个。常被听错的词，写在 = 后面")).apply { setPadding(ui.dp(8), 0, ui.dp(8), 0) }, field, counts, result, buttons)
        d = ui.sheet(this, L("粘贴导入"), body)
        d.window?.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE or android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        d.show()
        field.requestFocus()
    }
}
