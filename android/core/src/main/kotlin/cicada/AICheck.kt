package cicada

import cicada.Strings.L
import cicada.Strings.LF

/// What the last look at the AI service found, step by step (AICheck.swift): can this phone reach
/// it, does it take the key, does the text model answer, does the hear model take audio. A failed
/// step stops the ones after it, so the settings can say exactly where it broke and offer the one
/// thing that fixes it. The port has a fourth step the Mac doesn't: it hears through the service.
///
/// Most of the time the answer comes from real requests (hearing, notes, translation): every call
/// reports back here, so a meeting keeps the steps current without any extra request. An explicit
/// check runs only when the service, model or key changes, at launch, on 重新检查, and when the
/// network changes after the service was unreachable. Immutable: LingClient swaps in a new one.
data class AICheck(
    val steps: List<Step> = StepID.values().map { Step(it, State.Untested) },
    /** When the newest result came in (epoch ms); null before any. */
    val at: Long? = null,
    /** The newest result came from a real request in a meeting, not from a check. */
    val passive: Boolean = false,
    /** Where the phone's proxy stands when the service can't be reached: only read, to word the hint. */
    val proxy: ProxyHint? = null,
    /** OpenRouter only: dollars left (the smaller of the key's limit and the account's credits). */
    val balance: Double? = null,
    /** A custom service: how long one real sentence took, and whether the model thought first. */
    val translate: Speed? = null,
    /** A custom service whose notes go to another model or server: how that one answered. Null
     *  while notes use the translation model (then `steps` say it all). A notes failure doesn't
     *  stop translation: `failure` and `passed` stay about translation. */
    val notes: Notes? = null,
) {
    sealed class Notes {
        object Running : Notes() { override fun toString() = "running" }
        data class Ok(val seconds: Double) : Notes() {
            override fun toString() = "ok(${String.format(java.util.Locale.US, "%.1f", seconds)}s)"
        }
        data class Fail(val why: Reason, val code: Int? = null) : Notes() {
            override fun toString() = "fail(${lower(why.name)}${code?.let { " $it" } ?: ""})"
        }
        val ok get() = this is Ok
        val reason get() = (this as? Fail)?.why
    }

    data class Speed(val seconds: Double, val thinks: Boolean) {
        /// A sentence that takes this long often misses the 6 s a translation is given
        /// (Translator.translate) and falls back to Google.
        val slow get() = thinks || seconds >= SLOW_AFTER
        companion object { const val SLOW_AFTER = 3.0 }
    }

    enum class StepID { Reach, Key, Text, Hear }

    enum class Reason { Unreachable, BadAddress, InvalidKey, MgmtKey, NoCredit, NoModel, NoJSON, Deaf, Busy, ServerError }

    sealed class State {
        object Running : State()
        /** `seconds` of the request that proved it; null when it came with another step's request. */
        data class Ok(val seconds: Double? = null) : State()
        /** 429: the service is busy but the key works. Counts as passed. */
        object Busy : State()
        data class Fail(val reason: Reason, val code: Int? = null) : State()
        object Skipped : State()
        /** Nothing has proven it yet. */
        object Untested : State()
    }

    data class Step(val id: StepID, val state: State)

    /// A phone has no proxy app port to look for (the Mac's appRunning): only the system's.
    enum class ProxyHint { SystemOn, None }

    data class Failure(val step: StepID, val reason: Reason, val code: Int?)

    operator fun get(id: StepID): State = steps.firstOrNull { it.id == id }?.state ?: State.Untested

    fun with(id: StepID, state: State) = copy(steps = steps.map { if (it.id == id) Step(id, state) else it })

    /// The first step that failed, and why.
    val failure: Failure? get() {
        for (s in steps) { val st = s.state; if (st is State.Fail) return Failure(s.id, st.reason, st.code) }
        return null
    }

    val running get() = steps.any { it.state == State.Running } || notes == Notes.Running
    /** Translation works but the notes' own model or server doesn't (a busy one fixes itself). */
    val notesFailed get() = notes?.reason.let { it != null && it != Reason.Busy }
    val busy get() = steps.any { it.state == State.Busy }
    /** Every step passed (busy counts; a step nothing has tested yet does not block). */
    val passed get() = at != null && failure == null && !running
    val lowBalance get() = (balance ?: Double.POSITIVE_INFINITY) < LOW_BALANCE
    /** Text works but every sentence is slow (a thinking model): translations will fall back. */
    val slow get() = textFailure == null && translate?.slow == true
    /** The failure, unless it is only the hear model's (a custom service's rows show that apart). */
    val textFailure get() = failure?.takeIf { it.step != StepID.Hear }

    /** Something only the user can fix (a busy service fixes itself). */
    val needsUser: Boolean get() {
        val f = failure ?: return lowBalance
        return f.reason != Reason.Busy && f.reason != Reason.ServerError
    }

    /// `step` failed and the ones after it were never reached. `reached`: a reply came back, so the
    /// steps that request proves before it passed (false when nothing was sent, like a management key).
    fun fail(step: StepID, reason: Reason, code: Int? = null, reached: Boolean = true): AICheck {
        val proves = proves(step)
        var after = false
        val next = steps.map { s ->
            when {
                s.id == step -> { after = true; Step(s.id, State.Fail(reason, code)) }
                after -> Step(s.id, State.Skipped)
                reached && s.id in proves && !isOk(s.state) -> Step(s.id, State.Ok())
                // The text step comes before hearing but a hear request says nothing about it.
                s.id !in proves && s.state == State.Skipped -> Step(s.id, State.Untested)
                // Nothing was sent: the step a check had started on was never tried.
                s.state == State.Running -> Step(s.id, State.Untested)
                else -> s
            }
        }
        return copy(steps = next, proxy = if (reason == Reason.Unreachable) proxy else null)
    }

    /// One request proved `step` and what it rests on (a chat proves the address, the key and the
    /// text model; heard audio the address, the key and the hear model). Clears what failed before;
    /// steps that were skipped are open again.
    fun pass(step: StepID, seconds: Double?): AICheck {
        val proves = proves(step)
        val next = steps.map { s ->
            when {
                s.id == step -> Step(s.id, State.Ok(seconds))
                s.id in proves -> if (isOk(s.state)) s else Step(s.id, State.Ok())
                s.state == State.Skipped -> Step(s.id, State.Untested)
                else -> s
            }
        }
        return copy(steps = next, proxy = null)
    }

    // MARK: Words

    /// Why the failed step failed, in one sentence. `model`: the text model; `hearModel`: the hear model.
    fun message(service: String, host: String, model: String, hearModel: String): String? {
        val f = failure ?: return if (busy) LF("%@ 现在很忙，key 没问题。开会时会自动重试。", service) else null
        return when (f.reason) {
            Reason.Unreachable -> LF("这台手机访问不到 %@。", host)
            Reason.BadAddress -> L("地址要用 https；这台手机和局域网里的服务可以用 http。")
            Reason.InvalidKey -> LF("%@ 说这个 key 无效，可能没复制全，或已删除。", service)
            Reason.MgmtKey -> L("这是 ZenMux 的管理 key，不能用来调用模型。请粘贴 sk-payg 开头的 key。")
            Reason.NoCredit -> LF("%@ 账户余额不足。", service)
            Reason.NoModel -> LF("%@ 上找不到 %@ 这个模型。", service, model)
            Reason.NoJSON -> L("这个服务不支持 JSON，纪要写不了；翻译照常。")
            Reason.Deaf -> LF("%@ 听不了声音。", hearModel)
            Reason.Busy -> LF("%@ 现在很忙，key 没问题。开会时会自动重试。", service)
            Reason.ServerError -> LF("%@ 暂时出错（HTTP %lld），稍后再试。", service, f.code ?: 0)
        }
    }

    /// What stops listening or the notes until the user changes something (the Mac's
    /// AIServiceStrip.blocking): (what's wrong, what it stops). Not the network, a busy service or
    /// a server error: those fix themselves. Said beyond 设置, on the listening notification and the
    /// live screens. Models by their short name (after the last "/").
    fun blocking(service: String, textModel: String, hearModel: String): Pair<String, String>? {
        val f = failure ?: return null
        val stops = L("修好之前听不了")
        val notesStop = L("字幕照常，纪要先停下")
        return when (f.reason) {
            Reason.InvalidKey, Reason.MgmtKey -> LF("%@ 的 key 用不了", service) to stops
            Reason.NoCredit -> LF("%@ 账户余额不足。", service) to stops
            Reason.NoModel -> LF("%@ 上找不到 %@ 这个模型。", service, textModel.substringAfterLast('/')) to notesStop
            Reason.Deaf -> LF("%@ 听不了声音。", hearModel.substringAfterLast('/')) to stops
            Reason.BadAddress -> L("AI 服务的设置要改一下") to stops
            Reason.NoJSON -> L("AI 服务的设置要改一下") to notesStop
            Reason.Unreachable, Reason.Busy, Reason.ServerError -> null
        }
    }

    /// Why translations are slow, and what to do (a custom service).
    /// `googleOff`: 语音和文字只发给你的服务 is on, so a sentence that takes too long isn't handed to Google.
    fun slowLine(googleOff: Boolean = false): String? {
        val t = translate?.takeIf { slow } ?: return null
        val secs = String.format(Strings.locale, "%.1f", t.seconds)
        if (googleOff) return if (t.thinks) LF("这个模型先思考再回答，翻一句要 %@ 秒，超过 6 秒这句就不等它了。在服务端关掉思考，或换一个不思考的模型。", secs)
            else LF("翻一句要 %@ 秒，超过 6 秒这句就不等它了。换一个更小的模型会快一些。", secs)
        return if (t.thinks) LF("这个模型先思考再回答，翻一句要 %@ 秒，超过 6 秒会改用 Google。在服务端关掉思考，或换一个不思考的模型。", secs)
        else LF("翻一句要 %@ 秒，超过 6 秒会改用 Google。换一个更小的模型会快一些。", secs)
    }

    /// The notes' own model or server's problem, in one sentence. `sharedKey`: notes use the
    /// translation key, so a refused key wants one of their own.
    fun notesLine(host: String, model: String, sharedKey: Boolean): String? {
        val n = notes as? Notes.Fail ?: return null
        return when (n.why) {
            Reason.InvalidKey, Reason.MgmtKey ->
                if (sharedKey) LF("%@ 不认上面的 key，给它单独填一个。", host) else LF("%@ 说这个 key 无效，可能没复制全，或已删除。", host)
            Reason.Unreachable -> LF("这台手机访问不到 %@。", host)
            Reason.BadAddress -> L("地址要用 https；这台手机和局域网里的服务可以用 http。")
            Reason.NoCredit -> LF("%@ 账户余额不足。", host)
            Reason.NoModel -> LF("%@ 上找不到 %@ 这个模型。", host, model)
            Reason.NoJSON -> L("这个模型没按要求返回 JSON，写不了纪要。换一个通用模型。")
            Reason.Deaf, Reason.Busy -> null
            Reason.ServerError -> LF("%@ 暂时出错（HTTP %lld），稍后再试。", host, n.code ?: 0)
        }
    }

    /// The proxy line under "can't reach": what this phone's proxy looks like, and what to do.
    fun proxyLine(service: String, host: String): String? {
        if (failure?.reason != Reason.Unreachable) return null
        return when (proxy ?: return null) {
            ProxyHint.SystemOn -> LF("开了代理也连不上：换一个节点，或检查代理软件是否放过 %@。", host)
            ProxyHint.None -> LF("这台手机没开代理。在国内通常要开代理才能用 %@。", service)
        }
    }

    /// "OpenRouter 余额快用完了（还剩 $0.40）" when it is.
    fun balanceLine(service: String): String? {
        val b = balance ?: return null
        if (!lowBalance) return null
        return LF("%@ 余额快用完了（还剩 $%@）", service, String.format(java.util.Locale.US, "%.2f", maxOf(0.0, b)))
    }

    /// Debug and logs: "reach=ok key=fail(invalidKey) text=skipped hear=skipped".
    val summary: String get() {
        val parts = steps.joinToString(" ") { s ->
            val v = when (val st = s.state) {
                State.Running -> "running"
                is State.Ok -> st.seconds?.let { "ok(${String.format(java.util.Locale.US, "%.1f", it)}s)" } ?: "ok"
                State.Busy -> "busy"
                is State.Fail -> "fail(${lower(st.reason.name)}${st.code?.let { " $it" } ?: ""})"
                State.Skipped -> "skipped"
                State.Untested -> "untested"
            }
            "${lower(s.id.name)}=$v"
        }
        return parts + (proxy?.let { " proxy=${lower(it.name)}" } ?: "") +
            (balance?.let { " balance=${String.format(java.util.Locale.US, "%.2f", it)}" } ?: "") + (if (passive) " passive" else "") +
            (translate?.let { " translate=${String.format(java.util.Locale.US, "%.1f", it.seconds)}s${if (it.thinks) " thinks" else ""}" } ?: "") +
            (notes?.let { " notes=$it" } ?: "")
    }

    companion object {
        const val LOW_BALANCE = 0.5

        fun isOk(s: State) = s is State.Ok

        /// The steps a request that reached `step` also proves.
        fun proves(step: StepID): Set<StepID> = when (step) {
            StepID.Reach -> setOf(StepID.Reach)
            StepID.Key -> setOf(StepID.Reach, StepID.Key)
            StepID.Text -> setOf(StepID.Reach, StepID.Key, StepID.Text)
            StepID.Hear -> setOf(StepID.Reach, StepID.Key, StepID.Hear)
        }

        fun lower(name: String) = name.replaceFirstChar { it.lowercaseChar() }

        /// A reason by its debug name ("noModel"), for `ai-check-sim`.
        fun reasonNamed(name: String): Reason? = Reason.values().firstOrNull { lower(it.name).equals(name, ignoreCase = true) }

        fun title(id: StepID, host: String): String = when (id) {
            StepID.Reach -> LF("连上 %@", host)
            StepID.Key -> L("key 可以用")
            StepID.Text -> L("纪要和翻译")
            StepID.Hear -> L("听对方")
        }

        /// Which step a failed request stops at, and why. `step` is the step the request was
        /// proving: the text model for a chat, the hear model for heard audio (a 400/404/415/422
        /// there means the model doesn't take audio, not that it is missing).
        fun classify(e: LingException, step: StepID): Failure? = when (e.kind) {
            LingException.Kind.Network, LingException.Kind.Timeout -> Failure(StepID.Reach, Reason.Unreachable, null)
            LingException.Kind.InvalidKey -> Failure(StepID.Key, Reason.InvalidKey, null)
            LingException.Kind.RateLimited -> Failure(step, Reason.Busy, null)
            LingException.Kind.Http -> when {
                e.status == 402 -> Failure(StepID.Key, Reason.NoCredit, 402)
                step == StepID.Hear && e.status in DEAF_CODES -> Failure(StepID.Hear, Reason.Deaf, e.status)
                e.status == 400 || e.status == 404 ->
                    if (step == StepID.Key) Failure(StepID.Key, Reason.ServerError, e.status) else Failure(StepID.Text, Reason.NoModel, e.status)
                else -> Failure(step, Reason.ServerError, e.status)
            }
            LingException.Kind.NoKey, LingException.Kind.Hijacked, LingException.Kind.Parse -> null
        }

        /// What a hear model that doesn't take audio answers.
        val DEAF_CODES = listOf(400, 404, 415, 422)

        /// The prefix of a key says whose it is: `sk-or-` OpenRouter, `sk-payg` ZenMux, `sk-mgmt`
        /// ZenMux's management key (it can't call models). Null: nothing to tell.
        fun owner(key: String): Pair<String, Boolean>? {
            val k = key.trim()
            return when {
                k.startsWith("sk-or-") -> "openrouter" to false
                k.startsWith("sk-payg") -> "zenmux" to false
                k.startsWith("sk-mgmt") -> "zenmux" to true
                else -> null
            }
        }

        /// Every model id in a `/models` reply (null when the reply can't be read or lists none).
        fun listedModels(body: String): Set<String>? {
            val root = Json.parseObject(body) ?: return null
            val ids = root["data"].arr().mapNotNull { it.obj()?.get("id").str() }.filter { it.isNotEmpty() }
            return if (ids.isEmpty()) null else ids.toSet()
        }

        /// The ids a `/models` reply says take audio in. Null when it says nothing about what models
        /// take (a custom service, Ollama): then only the silent-audio probe can tell.
        fun listedHearing(body: String): Set<String>? {
            val root = Json.parseObject(body) ?: return null
            var told = false
            val ids = mutableSetOf<String>()
            for (raw in root["data"].arr()) {
                val m = raw.obj() ?: continue
                val id = m["id"].str() ?: continue
                val ins = (m["input_modalities"] ?: m["architecture"].obj()?.get("input_modalities")) ?: continue
                told = true
                if (ins.arr().any { it.str() == "audio" }) ids.add(id)
            }
            return if (told) ids else null
        }

        /// OpenRouter: dollars left from `/key` (`limit_remaining`, null without a key limit) and
        /// `/credits` (bought minus used); the smaller one is what the next meeting can spend.
        fun balance(key: Map<String, Any?>?, credits: Map<String, Any?>?): Double? {
            val k = key?.get("data").obj()?.get("limit_remaining").num()
            val d = credits?.get("data").obj()
            val total = d?.get("total_credits").num()
            val used = d?.get("total_usage").num()
            val c = if (total != null && used != null) total - used else null
            return when {
                k != null && c != null -> minOf(k, c)
                else -> k ?: c
            }
        }

        /// A made-up result for `reason` (debug screenshots of every state).
        fun simulated(reason: Reason): AICheck {
            val r = AICheck()
            return when (reason) {
                Reason.Busy -> r.pass(StepID.Text, 1.2).pass(StepID.Hear, 0.9).with(StepID.Text, State.Busy)
                Reason.Unreachable, Reason.BadAddress -> r.fail(StepID.Reach, reason, reached = false)
                Reason.InvalidKey, Reason.NoCredit -> r.fail(StepID.Key, reason, code = if (reason == Reason.NoCredit) 402 else null)
                Reason.MgmtKey -> r.fail(StepID.Key, reason, reached = false)
                Reason.NoModel, Reason.NoJSON -> r.fail(StepID.Text, reason, code = 404)
                Reason.Deaf -> r.pass(StepID.Text, 1.1).fail(StepID.Hear, reason, code = 400)
                Reason.ServerError -> r.fail(StepID.Text, reason, code = 503)
            }
        }
    }
}
