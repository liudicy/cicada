package com.wquguru.cicada

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.ConnectivityManager
import android.net.Uri
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import cicada.AICheck
import cicada.AICheck.Reason
import cicada.AICheck.State
import cicada.AICheck.StepID
import cicada.Strings
import cicada.Strings.L
import cicada.Strings.LF

/// The AI service's check, step by step (AICheckView.swift): 设置 › AI 服务 and the onboarding
/// show the same list; the home card and the 开始听 sheet say the same in fewer words. Every step
/// that ran shows its result; the one that failed says why in one line and offers the one thing
/// that fixes it.
object AiCheckViews {
    /// "Busy, retrying": a passing state that still deserves a word (Palette.warn on the Mac).
    val warn = Color.parseColor("#8A5900")
    val warnPale = Color.parseColor("#FFF4D6")
    val ok = Color.parseColor("#1E7B45")
    val okPale = Color.parseColor("#E3F3E8")

    /// The steps show while something is wrong or being checked; all passed folds into one line.
    fun showSteps(c: AICheck) = c.running || c.failure != null || c.busy || (c.at != null && !c.passed)

    /// The list of steps. `recheck`: 重新检查 in the failed step (onboarding; the settings have
    /// their own row). `changeKey` opens the key field.
    fun steps(a: Activity, ui: Ui, recheck: Boolean, changeKey: () -> Unit): LinearLayout {
        val app = a.cicada
        val ling = app.ling
        val c = ling.aiCheck
        val cfg = ling.config()
        val box = ui.stack(0)
        c.steps.forEachIndexed { i, step ->
            val st = step.state
            val row = LinearLayout(a).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(ui.dp(16), ui.dp(12), ui.dp(16), ui.dp(12))
            }
            row.addView(icon(ui, st), LinearLayout.LayoutParams(ui.dp(22), ui.dp(22)).apply { topMargin = ui.dp(1) })
            val faint = st == State.Skipped || st == State.Untested
            val texts = ui.stack(4, ui.text(AICheck.title(step.id, ling.serviceHost), 15f, if (faint) Palette.tertiary else Palette.ink, medium = true))
            if (st is State.Ok && step.id == StepID.Text && !cfg.isLing) texts.addView(ui.text(AiServiceActivity.short(cfg.textModel), 13f, Palette.tertiary, lines = 1))
            if (st is State.Ok && step.id == StepID.Hear && !cfg.isLing) texts.addView(ui.text(AiServiceActivity.short(cfg.hearModel), 13f, Palette.tertiary, lines = 1))
            if (st is State.Fail || st == State.Busy) problem(a, ui, texts, st == State.Busy, recheck, changeKey)
            row.addView(texts, ui.weight().apply { leftMargin = ui.dp(12) })
            if (st is State.Ok && st.seconds != null)
                row.addView(ui.text(LF("%@ 秒", "%.1f".format(Strings.locale, st.seconds)), 13f, Palette.tertiary, lines = 1).apply { fontFeatureSettings = "tnum" })
            row.contentDescription = AICheck.title(step.id, ling.serviceHost)
            if (i > 0) box.addView(ui.divider())
            box.addView(row)
        }
        return box
    }

    private fun icon(ui: Ui, s: State): View {
        val (glyph, fg, bg) = when (s) {
            is State.Ok -> Triple("✓", ok, okPale)
            is State.Fail -> Triple("✕", Palette.link, Palette.accentPale)
            State.Busy -> Triple("!", warn, warnPale)
            State.Running -> Triple("…", Palette.link, Palette.accentPale)
            else -> Triple("–", Palette.tertiary, Palette.ground)
        }
        return ui.text(glyph, 12f, fg, bold = true).apply { gravity = Gravity.CENTER; background = ui.rounded(bg, 11) }
    }

    /// Why it failed, the proxy hint when it's the network, and the fix: one dark button, at most one other.
    private fun problem(a: Activity, ui: Ui, into: LinearLayout, busy: Boolean, recheck: Boolean, changeKey: () -> Unit) {
        val ling = a.cicada.ling
        ling.checkMessage()?.let { into.addView(ui.text(it, 13f, if (busy) warn else Palette.link)) }
        ling.aiCheck.proxyLine(ling.serviceLabel, ling.serviceHost)?.let {
            into.addView(ui.text(it, 13f, Palette.body).apply {
                background = ui.rounded(Palette.ground, 10)
                setPadding(ui.dp(10), ui.dp(8), ui.dp(10), ui.dp(8))
            }, ui.lp(top = 4))
        }
        val acts = actions(a, recheck, changeKey)
        if (acts.isEmpty()) return
        val buttons = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL }
        acts.forEachIndexed { i, (title, run) ->
            buttons.addView(ui.button(title, if (i == 0) "primary" else "quiet", height = 40) { run() },
                            LinearLayout.LayoutParams(-2, -2).apply { if (i > 0) leftMargin = ui.dp(8) })
        }
        into.addView(buttons, ui.lp(top = 6))
    }

    /// One primary fix and at most one other, by why it failed.
    fun actions(a: Activity, recheck: Boolean, changeKey: () -> Unit): List<Pair<String, () -> Unit>> {
        val app = a.cicada
        val ling = app.ling
        val f = ling.aiCheck.failure ?: return emptyList()
        val p = ling.provider
        val cfg = ling.config()
        val again = if (recheck) listOf(L("重新检查") to { app.recheck() }) else emptyList()
        return when (f.reason) {
            // A server on the local network: the proxy help has nothing to say.
            Reason.Unreachable -> if (ling.unreachableNearby()) again else listOf<Pair<String, () -> Unit>>(L("怎么设置代理") to { open(a, helpUrl()) }) + again
            Reason.InvalidKey, Reason.MgmtKey ->
                listOf<Pair<String, () -> Unit>>(L("更换 key") to changeKey) + (p.site?.let { listOf<Pair<String, () -> Unit>>(LF("打开 %@", p.name) to { open(a, it) }) } ?: emptyList())
            Reason.NoCredit -> listOf<Pair<String, () -> Unit>>(L("去充值") to { open(a, topUp(p)) }) + again
            Reason.NoModel -> recommended(p.textModels.firstOrNull()?.id, cfg.textModel)?.let { listOf<Pair<String, () -> Unit>>(LF("换成推荐的 %@", AiServiceActivity.short(it)) to { app.useRecommended("text") }) } ?: again
            Reason.Deaf -> recommended(p.hearModels.firstOrNull()?.id, cfg.hearModel)?.let { listOf<Pair<String, () -> Unit>>(LF("换成推荐的 %@", AiServiceActivity.short(it)) to { app.useRecommended("hear") }) } ?: again
            Reason.ServerError -> again
            Reason.BadAddress, Reason.NoJSON, Reason.Busy -> emptyList()
        }
    }

    private fun recommended(first: String?, current: String) = first?.takeIf { it != current }

    /// Where to add money: OpenRouter's credits page, else the service's own site.
    fun topUp(p: cicada.Provider) = if (p.id == "openrouter") "https://openrouter.ai/settings/credits" else p.site ?: "https://zenmux.ai"

    /// The website's proxy help, in the UI language.
    fun helpUrl(): String {
        val prefix = when (Strings.language) { "en" -> "/en"; "ja" -> "/ja"; "ko" -> "/ko"; else -> "" }
        return "https://cicada.indaloop.app$prefix/start/#proxy"
    }

    fun open(a: Context, url: String) {
        try { a.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } catch (_: Exception) {}
    }

    /// All passed, in one line: "已连接 · 文字 1.8 秒 · 听 0.9 秒", or when the newest evidence came
    /// from a meeting, "正常 · 12 分钟前开会时用过". Null otherwise.
    fun summary(c: AICheck): String? {
        if (!c.passed || c.busy) return null
        val at = c.at
        if (c.passive && at != null) return L("正常") + " · " +
            // Under a minute ICU says "now", which reads as in use right now: "just now", as on Linux.
            (if (System.currentTimeMillis() - at < 60_000) L("刚刚开会时用过") else LF("%@ 开会时用过", relative(at)))
        val text = (c[StepID.Text] as? State.Ok)?.seconds
        val hear = (c[StepID.Hear] as? State.Ok)?.seconds
        val parts = listOfNotNull(text?.let { LF("文字 %@ 秒", "%.1f".format(Strings.locale, it)) }, hear?.let { LF("听 %@ 秒", "%.1f".format(Strings.locale, it)) })
        return (listOf(L("已连接")) + parts).joinToString(" · ")
    }

    /// "2 分钟前" in the app's language (not the phone's, which may differ).
    fun relative(at: Long): String {
        val f = android.icu.text.RelativeDateTimeFormatter.getInstance(android.icu.util.ULocale.forLocale(Strings.locale), null,
            android.icu.text.RelativeDateTimeFormatter.Style.SHORT, android.icu.text.DisplayContext.CAPITALIZATION_NONE)
        val minutes = (System.currentTimeMillis() - at) / 60_000
        return when {
            minutes < 1 -> f.format(android.icu.text.RelativeDateTimeFormatter.Direction.PLAIN, android.icu.text.RelativeDateTimeFormatter.AbsoluteUnit.NOW)
            minutes < 60 -> f.format(minutes.toDouble(), android.icu.text.RelativeDateTimeFormatter.Direction.LAST, android.icu.text.RelativeDateTimeFormatter.RelativeUnit.MINUTES)
            minutes < 60 * 24 -> f.format((minutes / 60).toDouble(), android.icu.text.RelativeDateTimeFormatter.Direction.LAST, android.icu.text.RelativeDateTimeFormatter.RelativeUnit.HOURS)
            else -> f.format((minutes / 1440).toDouble(), android.icu.text.RelativeDateTimeFormatter.Direction.LAST, android.icu.text.RelativeDateTimeFormatter.RelativeUnit.DAYS)
        }
    }

    // MARK: Home card (there is no tray: the card sits where 有新版本 does)

    /// Title and detail when the user must fix something; null otherwise. On a phone the service
    /// hears too, so most failures stop listening, not just the notes.
    fun cardWords(app: CicadaApp): Pair<String, String>? {
        val ling = app.ling
        val c = ling.aiCheck
        if (!ling.hasKey || !c.needsUser || c.running) return null
        val name = ling.serviceLabel
        val cfg = ling.config()
        val f = c.failure ?: return c.balanceLine(name)?.let { it to L("用完后就听不了了") }
        if (f.reason == Reason.Unreachable) return LF("连不上 %@", name) to L("修好之前听不了")
        return c.blocking(name, cfg.textModel, cfg.hearModel)
    }

    fun card(a: Activity, ui: Ui): View? {
        val (title, detail) = cardWords(a.cicada) ?: return null
        return LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = ui.rounded(Palette.card, 22)
            setPadding(ui.dp(16), ui.dp(12), ui.dp(8), ui.dp(12))
            addView(ui.tile(R.drawable.i_info, 40, Palette.accentPale, Palette.link).apply { background = ui.rounded(Palette.accentPale, 20) })
            addView(ui.stack(2, ui.text(title, 15f, Palette.ink, medium = true), ui.helper(detail)), ui.weight().apply { leftMargin = ui.dp(12) })
            addView(ui.textButton(L("打开设置")) { a.startActivity(Intent(a, AiServiceActivity::class.java)) })
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
    }

    // MARK: 开始听

    /// 开始听 stops only on a failure already known: a hear model that takes no audio, or a service
    /// that still can't be reached after one more look. Anything else (unknown, busy) just starts.
    fun start(a: Activity, kind: String) {
        val app = a.cicada
        val ling = app.ling
        // Already looking (the re-check below takes up to 20 s offline): one sheet, not two.
        if (ling.aiCheck.running) return
        when (ling.aiCheck.failure?.reason) {
            Reason.Deaf -> deafSheet(a, kind)
            Reason.Unreachable -> {
                app.startProblem = L("正在检查…"); app.changed()
                app.background.execute {
                    ling.check()
                    app.main.post {
                        app.startProblem = null; app.changed()
                        if (a.isFinishing || a.isDestroyed) return@post
                        when (ling.aiCheck.failure?.reason) {
                            Reason.Unreachable -> unreachableSheet(a, kind)
                            Reason.Deaf -> deafSheet(a, kind)
                            else -> app.startListening(a, kind, gate = false)
                        }
                    }
                }
            }
            else -> app.startListening(a, kind, gate = false)
        }
    }

    /// Whether 开始听 must stop and say why first (the tile hands it to the home screen).
    fun blocks(app: CicadaApp) = app.ling.aiCheck.failure?.reason.let { it == Reason.Deaf || it == Reason.Unreachable }

    private fun deafSheet(a: Activity, kind: String) {
        val app = a.cicada
        val ui = Ui(a)
        val cfg = app.ling.config()
        val model = AiServiceActivity.short(cfg.hearModel)
        val rec = recommended(cfg.provider.hearModels.firstOrNull()?.id, cfg.hearModel)
        lateinit var d: android.app.Dialog
        val body = ui.stack(0, ui.text(LF("%@ 只收文字。换成推荐的模型就能开始听。", model), 15f, Palette.secondary).apply { gravity = Gravity.CENTER; setPadding(ui.dp(12), 0, ui.dp(12), 0) })
        body.addView(buttons(ui, L("打开设置") to { d.dismiss(); a.startActivity(Intent(a, AiServiceActivity::class.java)) },
            rec?.let { L("换成推荐的并开始") to { d.dismiss(); app.useRecommended("hear"); app.startListening(a, kind, gate = false) } }), ui.lp(top = 18))
        d = ui.sheet(a, LF("%@ 现在听不了声音", model), body)
        d.show()
    }

    private fun unreachableSheet(a: Activity, kind: String) {
        val app = a.cicada
        val ling = app.ling
        val ui = Ui(a)
        lateinit var d: android.app.Dialog
        val body = ui.stack(10)
        ling.checkMessage()?.let { body.addView(ui.text(it, 15f, Palette.secondary).apply { gravity = Gravity.CENTER }) }
        ling.aiCheck.proxyLine(ling.serviceLabel, ling.serviceHost)?.let {
            body.addView(ui.text(it, 14f, Palette.body).apply { background = ui.rounded(Palette.ground, 12); setPadding(ui.dp(12), ui.dp(10), ui.dp(12), ui.dp(10)) })
        }
        body.addView(ui.textButton(L("怎么设置代理")) { open(a, helpUrl()) }.apply {
            layoutParams = LinearLayout.LayoutParams(-2, -2).apply { gravity = Gravity.CENTER_HORIZONTAL }
        })
        body.addView(buttons(ui, L("打开设置") to { d.dismiss(); a.startActivity(Intent(a, AiServiceActivity::class.java)) },
            L("重新检查并开始") to { d.dismiss(); start(a, kind) }), ui.lp(top = 8))
        d = ui.sheet(a, LF("连不上 %@", ling.serviceName), body)
        d.show()
    }

    /// The fix on top, full width: side by side, English cut "Check Again and Start" short.
    private fun buttons(ui: Ui, quiet: Pair<String, () -> Unit>, primary: Pair<String, () -> Unit>?) = ui.stack(10).apply {
        if (primary != null) addView(ui.button(primary.first, "primary") { primary.second() })
        addView(ui.button(quiet.first, "quiet") { quiet.second() })
    }

    // MARK: Proxy (read only, to word the hint; the app never sets or uses a proxy of its own)

    /// A proxy set on the network in use (Wi-Fi › 代理, or a VPN app's), or for the whole phone.
    /// A phone has no proxy app port to look for, so only "on" or "none".
    fun proxyHint(context: Context): AICheck.ProxyHint {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val link = try { cm?.getLinkProperties(cm.activeNetwork)?.httpProxy } catch (_: Exception) { null }
        val global = try { cm?.defaultProxy } catch (_: Exception) { null }
        val prop = System.getProperty("https.proxyHost") ?: System.getProperty("http.proxyHost")
        val on = link?.host?.isNotEmpty() == true || link?.pacFileUrl?.let { it != Uri.EMPTY } == true ||
            global?.host?.isNotEmpty() == true || !prop.isNullOrEmpty()
        cicada.Log.d("ai: proxy link=${link != null} global=${global != null} property=${!prop.isNullOrEmpty()} -> ${if (on) "on" else "none"}")
        return if (on) AICheck.ProxyHint.SystemOn else AICheck.ProxyHint.None
    }
}
