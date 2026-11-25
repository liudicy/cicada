// AI 服务: the services other than Ling (Providers.kt), the same cases as the Linux port's
// tests/test_providers.py. No network: LingClient runs against a fake transport.
package cicada.cli

import cicada.*
import java.io.ByteArrayInputStream
import java.util.Base64

object ProviderTests {
    val tests: List<Pair<String, () -> Unit>> = listOf(
        "aiDefaultsAreTheRecommendedModels" to ::defaults,
        "aiChosenModelsAndACustomService" to ::chosenAndCustom,
        "aiCustomAddress" to ::customAddress,
        "aiSettingsKeepTheServiceAcrossARestart" to ::settingsRoundTrip,
        "aiCustomOnlyActsOnTheCustomServiceAlone" to ::customOnlySetting,
        "aiCustomOnlyPartialLinesNeverGoToGoogle" to ::customOnlyDrafts,
        "aiCustomOnlySentencesGoToTheServiceAlone" to ::customOnlySentences,
        "aiCustomOnlyFlippingItForgetsTheGoogleBackoff" to ::customOnlyClearsBackoff,
        "aiEachServiceTurnsThinkingOffItsOwnWay" to ::shape,
        "aiAudioGoesInTheFormEachModelTakes" to ::audioPart,
        "aiCatalogListsChatModelsAndThoseThatHear" to ::catalog,
        "aiOneKeyFilePerService" to ::oneKeyFilePerService,
        "aiALocalCustomServiceNeedsNoKey" to ::localNeedsNoKey,
        "aiRequestsGoToTheServiceInItsShape" to ::requestShape,
        "aiLingStillDropsRepliesWithoutAFinishReason" to ::lingDropsNoFinish,
        "aiCheckFindsAHearModelThatRefusesAudio" to ::checkFindsDeafModel,
        "aiCheckSaysWhy" to ::checkSaysWhy,
        "aiSpeechFromEachService" to ::speech,
        "aiNoVoiceModelNoSpeech" to ::noVoiceNoSpeech,
        "aiHearingUsesTheHearModel" to ::hearingUsesHearModel,
        "aiProblemsNameTheService" to ::problemsNameTheService,
        "aiAClockIsNotSpeech" to ::clockIsNotSpeech,
        "aiFinalNotesKeepRetryingForAboutAMinute" to ::finalNotesRetry,
        "aiTheLocalNetworkMayUsePlainHTTP" to ::localNetwork,
        "aiCustomTurnsThinkingOffThroughTheChatTemplate" to ::templateKwargs,
        "aiAThinkingModelIsSeenFromItsReply" to ::thought,
        "aiASlowSentenceIsFlagged" to ::slowSentence,
        "aiAServerThatRefusesTemplateKwargsIsAskedWithout" to ::kwargsRefused,
        "aiARefusalForSomethingElseKeepsThinkingOff" to ::jsonModeRefused,
        "aiACheckPassesAModelThatAnswersJSONWithoutJSONMode" to ::checkWithoutJSONMode,
        "aiAJSONObjectInPlainTextCountsAsJSON" to ::answersJSON,
        "aiCustomCheckTimesARealSentence" to ::customCheckTimes,
        "aiTheHearModelMayHaveItsOwnAddress" to ::hearBase,
        "aiAHearServerThatCantBeReachedFailsHearing" to ::hearServerDown,
        "aiNotesGoToTheirModelAndServerTranslationStays" to ::notesApart,
        "aiNotesWithoutTheirOwnKeyUseTheTranslationKey" to ::notesSharedKey,
        "aiARefusedNotesKeyLeavesTranslationWorking" to ::notesKeyRefused,
        "aiNotesFallBackToTranslationUntilSet" to ::notesConfig,
        "aiNotesWithABadAddressAreNeverSentToTranslation" to ::notesBadAddress,
        "aiACheckTestsNotesApartWithoutFailingTranslation" to ::notesCheck,
        "aiEachServerHasItsOwnStartGate" to ::gatePerServer,
    )

    private fun check(ok: Boolean, what: String) { if (!ok) throw AssertionError(what) }
    private fun <T> equal(expected: T, actual: T, what: String) { if (expected != actual) throw AssertionError("$what: expected «$expected», got «$actual»") }

    /// Answers by URL and body; records what was sent and streamed.
    private class Fake(
        val respond: (String, String) -> Transport.Response,
        val streams: ((String, String) -> Transport.Stream)? = null,
    ) : Transport {
        val sent = mutableListOf<Pair<String, String>>()
        /// The Authorization header of each request in `sent`.
        val auths = mutableListOf<String?>()
        val streamed = mutableListOf<Pair<String, String>>()
        override fun send(url: String, method: String, body: String?, headers: Map<String, String>, timeoutMs: Int): Transport.Response {
            synchronized(sent) { sent.add(url to (body ?: "")); auths.add(headers["Authorization"]) }
            return respond(url, body ?: "")
        }
        override fun stream(url: String, body: String, headers: Map<String, String>, timeoutMs: Int): Transport.Stream {
            streamed.add(url to body)
            return streams!!(url, body)
        }
    }

    private fun reply(content: String, finish: String? = "stop") = Transport.Response(200, Json.write(mapOf(
        "choices" to listOf(mapOf("message" to mapOf("content" to content), "finish_reason" to finish)),
    ), pretty = false))

    private fun client(fake: Transport, s: AppSettings, key: String? = "sk-test-0000000000"): LingClient {
        val k = AIKey(PlainProtector, service = { s.aiProvider })
        k.remove()
        if (key != null) k.save(key)
        return LingClient(k, fake, config = s::aiConfig)
    }

    private fun body(s: String) = Json.parse(s).obj()!!

    fun defaults() {
        val c = AppSettings(aiProvider = "zenmux").aiConfig()
        equal("https://zenmux.ai/api/v1/", c.base, "base")
        equal("qwen/qwen3.8-omni-flash", c.hearModel, "hear")
        equal("inclusionai/ling-3.0-flash", c.textModel, "text")
        equal("google/gemini-3.8-flash-tts", c.voiceModel, "voice")
        val ling = AppSettings().aiConfig()
        equal("Ming-3.0-audio-flash" to "Ling-3.1-flash", ling.hearModel to ling.textModel, "Ling")
        // Ling keeps its own key ("model"); a service never named falls back to Ling.
        equal("Ling-3.0-flash", AppSettings(model = "Ling-3.0-flash").aiConfig().textModel, "Ling's model")
        equal("ling", Providers.named("openai").id, "no OpenAI")
    }

    fun chosenAndCustom() {
        var s = AppSettings(aiProvider = "openrouter", aiHearModels = mutableMapOf("openrouter" to "google/gemini-3.1-flash-lite"))
        equal("google/gemini-3.1-flash-lite", s.aiConfig().hearModel, "chosen hear model")
        s = AppSettings(aiProvider = "custom", aiCustomBase = "localhost:11434/v1", aiModels = mutableMapOf("custom" to "qwen3:14b"))
        val c = s.aiConfig()
        equal("http://localhost:11434/v1/", c.base, "local base")
        equal("", c.hearModel, "no hear model yet")
        check(!c.hasVoices, "no voices without a speech model")
        s.aiVoiceModels["custom"] = "kokoro"; s.aiCustomVoice = "af_heart"
        equal("kokoro" to "http://localhost:11434/v1/", s.aiConfig().voiceModel to s.aiConfig().voiceBase, "custom voice")
        equal(listOf("af_heart"), s.aiConfig().voices.map { it.id }, "custom voice name")
    }

    fun customAddress() {
        equal("https://api.example.com/v1/", Providers.customBase("api.example.com/v1"), "https added")
        equal("http://127.0.0.1:1234/v1/", Providers.customBase("127.0.0.1:1234/v1"), "http on this device")
        equal(null, Providers.customBase("http://api.example.com/v1"), "http only on this device")
        equal(null, Providers.customBase(" "), "empty")
    }

    fun localNetwork() {
        for (ok in listOf("http://192.168.1.20:8000/v1", "10.0.0.5:8000/v1", "http://172.20.1.1/v1", "http://100.101.102.103:8000/v1",
                          "http://169.254.3.4/v1", "http://gpu.local:30000/v1", "http://[fd12:3456::1]:8000/v1", "http://[fe80::1]/v1",
                          "http://[::1]:8000/v1", "http://localhost:8000/v1"))
            equal("http", Providers.customBase(ok)?.substringBefore("://"), ok)
        for (no in listOf("http://172.32.0.1/v1", "http://172.15.0.1/v1", "http://100.128.0.1/v1", "http://100.63.0.1/v1", "http://8.8.8.8/v1",
                          "http://192.169.1.1/v1", "http://gpu.example.com/v1", "http://10.0.0.5.evil.com/v1", "http://10.0.0.256/v1",
                          "http://[2001:db8::1]/v1"))
            equal(null, Providers.customBase(no), no)
        equal("http://192.168.1.20:8000/v1/", Providers.customBase("192.168.1.20:8000/v1"), "http added for a nearby host")
        equal("https://10.0.0.5.evil.com/v1/", Providers.customBase("10.0.0.5.evil.com/v1"), "https added for a lookalike")
        check(Providers.isNearby("http://192.168.1.20:8000/v1/") && !Providers.isLocal("http://192.168.1.20:8000/v1/"), "nearby, not local")
        // A service on the local network needs no key either.
        val s = AppSettings(aiProvider = "custom", aiCustomBase = "192.168.1.20:8000/v1", aiModels = mutableMapOf("custom" to "qwen3:14b"))
        equal("", client(Fake({ _, _ -> reply("ok") }), s, key = null).currentKey(), "no key on the LAN")
    }

    fun templateKwargs() {
        val custom = AppSettings(aiProvider = "custom", aiCustomBase = "http://192.168.1.20:8000/v1").aiConfig()
        val b = mutableMapOf<String, Any?>()
        custom.shape(b, 50)
        equal(mapOf("enable_thinking" to false), b["chat_template_kwargs"], "Qwen3 on vLLM / SGLang / llama.cpp: thinking off")
        val plain = mutableMapOf<String, Any?>()
        custom.shape(plain, 50, templateKwargs = false)
        check("chat_template_kwargs" !in plain, "left out for a server that refused it")
        for (id in listOf("ling", "zenmux", "openrouter")) {
            val o = mutableMapOf<String, Any?>()
            AppSettings(aiProvider = id).aiConfig().shape(o, 50)
            check("chat_template_kwargs" !in o, "$id never gets it")
        }
    }

    fun thought() {
        fun r(message: Map<String, Any?>, usage: Map<String, Any?>? = null): Map<String, Any?> =
            mapOf("choices" to listOf(mapOf("message" to message))) + (usage?.let { mapOf("usage" to it) } ?: emptyMap())
        check(!AIConfig.thought(r(mapOf("content" to "周五发布。"))), "a plain answer")
        check(AIConfig.thought(r(mapOf("content" to "周五发布。", "reasoning_content" to "The user wants…"))), "reasoning_content")
        // A reasoning parser on the server: the answer itself sits in reasoning_content.
        check(AIConfig.thought(r(mapOf("content" to "", "reasoning_content" to "周五发布。"))), "answer in reasoning_content")
        check(AIConfig.thought(r(mapOf("content" to "周五发布。", "reasoning" to "hmm"))), "reasoning (OpenRouter's name)")
        check(AIConfig.thought(r(mapOf("content" to "<think>hmm</think>周五发布。"))), "<think>")
        check(AIConfig.thought(r(mapOf("content" to "周五发布。"), mapOf("completion_tokens_details" to mapOf("reasoning_tokens" to 212)))), "reasoning tokens")
        check(!AIConfig.thought(r(mapOf("content" to "周五发布。", "reasoning_content" to "  "), mapOf("completion_tokens_details" to mapOf("reasoning_tokens" to 0)))), "blank and zero")
    }

    fun slowSentence() {
        check(!AICheck.Speed(0.4, false).slow, "fast")
        check(AICheck.Speed(0.4, true).slow, "thinks")
        check(AICheck.Speed(6.4, false).slow, "slow")
        val c = AICheck(at = 1).pass(AICheck.StepID.Text, 4.2).copy(translate = AICheck.Speed(4.2, true))
        check(c.slow && c.slowLine()!!.contains("4.2"), "the slow line says how long")
        check("Google" in c.slowLine()!!, "Google stands in for a slow sentence")
        val off = c.slowLine(googleOff = true)!!
        check("4.2" in off && "Google" !in off && "不等它了" in off, "语音和文字只发给你的服务: no word of Google")
        val plain = AICheck(at = 1).pass(AICheck.StepID.Text, 6.4).copy(translate = AICheck.Speed(6.4, false)).slowLine(googleOff = true)!!
        check("Google" !in plain && "更小的模型" in plain, "a slow model that doesn't think, without Google")
        check(AICheck(at = 1).pass(AICheck.StepID.Text, 0.5).copy(translate = AICheck.Speed(0.5, false)).slowLine() == null, "nothing to say")
        check("translate=4.2s thinks" in c.summary, "in the summary (the settings repaint on it)")
    }

    fun kwargsRefused() {
        val s = AppSettings(aiProvider = "custom", aiCustomBase = "http://192.168.1.20:8000/v1", aiModels = mutableMapOf("custom" to "m"))
        val fake = Fake({ _, b -> if ("chat_template_kwargs" in b) Transport.Response(422, "{}") else reply("好") })
        val ling = client(fake, s, key = null)
        equal("好", ling.chat("c", "i", Priority.Translate), "answered without it")
        equal(2, fake.sent.size, "asked twice")
        check("chat_template_kwargs" in fake.sent[0].second && "chat_template_kwargs" !in fake.sent[1].second, "the retry leaves it out")
        ling.chat("c", "i", Priority.Translate)
        equal(3, fake.sent.size, "not sent again")
        ling.keyChanged()
        ling.chat("c", "i", Priority.Translate)
        check("chat_template_kwargs" in fake.sent[3].second, "back after settings change")
        // A second refusal is about something else: the field isn't given up.
        val deaf = Fake({ _, _ -> Transport.Response(400, "{}") })
        val other = client(deaf, s, key = null)
        try { other.chat("c", "i", Priority.Translate); throw AssertionError("accepted") } catch (e: LingException) { equal(400, e.status, "the refusal") }
        try { other.chat("c", "i", Priority.Translate) } catch (_: LingException) {}
        equal(4, deaf.sent.size, "each call tried both ways")
        check("chat_template_kwargs" in deaf.sent[2].second, "still sent")
    }

    fun jsonModeRefused() {
        // No JSON mode on this server (OpenRouter's Novita for Ling 3.1 Flash): 400 with or without
        // the kwargs. Asked again without JSON mode.
        val s = AppSettings(aiProvider = "custom", aiCustomBase = "http://192.168.1.20:8000/v1", aiModels = mutableMapOf("custom" to "m"))
        val fake = Fake({ _, b -> if ("response_format" in b) Transport.Response(400, "{}") else reply("好") })
        val ling = client(fake, s, key = null)
        equal("好", ling.chat("x", "Notes.", Priority.Translate, json = true), "answered without JSON mode")
        val last = fake.sent.last().second
        check("response_format" !in last && "chat_template_kwargs" in last, "thinking stays off")
        ling.chat("y", "Translate.", Priority.Translate)
        check("chat_template_kwargs" in fake.sent.last().second, "and is not dropped for later requests")
    }

    fun checkWithoutJSONMode() {
        val s = AppSettings(aiProvider = "custom", aiCustomBase = "http://192.168.1.20:8000/v1", aiModels = mutableMapOf("custom" to "m"),
                            aiHearModels = mutableMapOf("custom" to "m"))
        val fake = Fake({ url, b -> if (url.endsWith("models")) Transport.Response(404, "") else if ("response_format" in b) Transport.Response(400, "{}")
                          else if ("JSON object" in b) reply("```json\n{\"ok\": true}\n```") else reply("周五发布。") })
        val ling = client(fake, s, key = null)
        ling.check()
        check(ling.aiCheck.failure == null, "passes: ${ling.aiCheck.summary}")
        // One that can't answer JSON at all still fails.
        val plain = Fake({ url, b -> if (url.endsWith("models")) Transport.Response(404, "") else if ("response_format" in b) Transport.Response(400, "{}") else reply("ok") })
        val other = client(plain, s, key = null)
        other.check()
        equal(AICheck.Reason.NoJSON, other.aiCheck.failure?.reason, "no JSON either way")
        equal(400, other.aiCheck.failure?.code, "the refusal's code")
    }

    fun answersJSON() {
        check(LingClient.answersJSON("{\"ok\": true}"), "bare")
        check(LingClient.answersJSON("```json\n{\"ok\": true}\n```"), "fenced")
        check(!LingClient.answersJSON("ok") && !LingClient.answersJSON("} {") && !LingClient.answersJSON(null), "none")
    }

    fun customCheckTimes() {
        val s = AppSettings(aiProvider = "custom", aiCustomBase = "http://192.168.1.20:8000/v1", aiModels = mutableMapOf("custom" to "qwen3:14b"),
                            aiHearModels = mutableMapOf("custom" to "qwen3-omni"))
        val thinking = Transport.Response(200, Json.write(mapOf("choices" to listOf(mapOf(
            "message" to mapOf("content" to "我们会在周五设计评审后发布新版本。", "reasoning_content" to "Okay, the user…"), "finish_reason" to "stop"))), pretty = false))
        val fake = Fake({ url, b -> if (url.endsWith("models")) Transport.Response(404, "") else if ("Translate the text" in b) thinking else reply("{\"ok\": true}") })
        val ling = client(fake, s, key = null)
        ling.check()
        val first = body(fake.sent[0].second)
        equal(120, first["max_tokens"].num()?.toInt(), "a real sentence's room")
        check("ship the new version on Friday" in first["messages"].arr()[0].obj()!!["content"].str()!!, "the sentence")
        equal("Translate.", first["messages"].arr()[1].obj()!!["content"], "the instruction")
        val t = ling.aiCheck.translate
        check(t != null && t.thinks, "thinking found: ${ling.aiCheck.summary}")
        check(ling.aiCheck.slow && ling.aiCheck.failure == null, "works, but slow")
        // All 120 tokens spent thinking, no answer: still a thinking model, not a silent pass.
        val noAnswer = Transport.Response(200, Json.write(mapOf("choices" to listOf(mapOf(
            "message" to mapOf("content" to null, "reasoning" to "Okay, the user wants…"), "finish_reason" to "length"))), pretty = false))
        val spent = client(Fake({ url, b -> if (url.endsWith("models")) Transport.Response(404, "") else if ("Translate the text" in b) noAnswer else reply("{\"ok\": true}") }), s, key = null)
        spent.check()
        check(spent.aiCheck.translate?.thinks == true && spent.aiCheck.slow, "thinking found without an answer: ${spent.aiCheck.summary}")
    }

    fun hearBase() {
        val s = AppSettings(aiProvider = "custom", aiCustomBase = "http://192.168.1.20:8000/v1", aiModels = mutableMapOf("custom" to "m"),
                            aiHearModels = mutableMapOf("custom" to "qwen3-omni"))
        equal("http://192.168.1.20:8000/v1/", s.aiConfig().hearBase, "empty: the text model's address")
        check(!s.aiConfig().hearsElsewhere, "same server")
        s.aiCustomHearBase = "192.168.1.21:8001/v1"
        equal("http://192.168.1.21:8001/v1/", s.aiConfig().hearBase, "its own")
        check(s.aiConfig().hearsElsewhere, "another server")
        s.aiCustomHearBase = "http://hear.example.com/v1"
        equal(null, s.aiConfig().hearBase, "not a valid address")
        equal("https://zenmux.ai/api/v1/", AppSettings(aiProvider = "zenmux").aiConfig().hearBase, "others: the service's")
        s.aiCustomHearBase = "192.168.1.21:8001/v1"
        val fake = Fake({ _, _ -> reply("LANG: en\nORIGINAL: Hi.\nTRANSLATION: 嗨。") })
        val ling = client(fake, s, key = null)
        ling.chat("c", "i", Priority.Translate, model = s.aiConfig().hearModel, audio = byteArrayOf(1))
        equal("http://192.168.1.21:8001/v1/chat/completions", fake.sent[0].first, "audio to the hear model's address")
        ling.chat("c", "i", Priority.Translate)
        equal("http://192.168.1.20:8000/v1/chat/completions", fake.sent[1].first, "text to the text model's")
        equal("192.168.1.21", ling.hearName, "a hearing problem names the hear model's address")
        try {
            s.aiCustomHearBase = "http://192.168.1.21:8001/v1"
            s.save()
            equal("http://192.168.1.21:8001/v1", AppSettings.load().aiCustomHearBase, "kept across a restart")
        } finally { Paths.settings.delete() }
    }

    fun hearServerDown() {
        val s = AppSettings(aiProvider = "custom", aiCustomBase = "http://192.168.1.20:8000/v1", aiModels = mutableMapOf("custom" to "m"),
                            aiHearModels = mutableMapOf("custom" to "qwen3-omni"), aiCustomHearBase = "http://192.168.1.21:8001/v1")
        val fake = Fake({ url, _ ->
            when {
                url.endsWith("models") -> Transport.Response(404, "")
                "192.168.1.21" in url -> throw java.io.IOException("down")
                else -> reply("{\"ok\": true}")
            }
        })
        val ling = client(fake, s, key = null)
        ling.proxyHint = { AICheck.ProxyHint.None }
        ling.check()
        val f = ling.aiCheck.failure
        equal(AICheck.StepID.Hear to AICheck.Reason.Unreachable, f?.step to f?.reason, "the hear step: ${ling.aiCheck.summary}")
        check(ling.checkMessage()!!.contains("192.168.1.21"), "names the hear server: ${ling.checkMessage()}")
        equal(null, ling.aiCheck.proxy, "no proxy hint for a server on the local network")
        // A bad hear address stops at hearing, not at the text model's.
        s.aiCustomHearBase = "http://hear.example.com/v1"
        ling.keyChanged()
        ling.check()
        equal(AICheck.StepID.Hear to AICheck.Reason.BadAddress, ling.aiCheck.failure?.step to ling.aiCheck.failure?.reason, "bad hear address")
        check(!ling.canHear, "listening can't start without a hear address")
    }

    fun settingsRoundTrip() {
        try {
            AppSettings(aiProvider = "zenmux", aiHearModels = mutableMapOf("zenmux" to "bytedance/doubao-seed-2.0-mini"), aiCustomOnly = true).save()
            val back = AppSettings.load()
            equal("zenmux", back.aiProvider, "service")
            equal("bytedance/doubao-seed-2.0-mini", back.aiConfig().hearModel, "hear model")
            check(back.aiCustomOnly, "语音和文字只发给你的服务 kept")
        } finally { Paths.settings.delete() }
    }

    // MARK: 语音和文字只发给你的服务 (issue #15; the Mac's GoogleOffTests)

    private fun custom(on: Boolean = true) = AppSettings(aiProvider = "custom", aiCustomBase = "http://127.0.0.1:8000/v1",
        aiModels = mutableMapOf("custom" to "qwen3:14b"), aiHearModels = mutableMapOf("custom" to "qwen3-omni"), aiCustomOnly = on)

    private fun google(url: String) = "translate.googleapis.com" in url
    private val googleReply = Transport.Response(200, "[[[\"我们周五发布\",\"We ship on Friday\"]]]")

    fun customOnlySetting() {
        check(custom().customOnly, "in effect with the custom service")
        check(!custom(on = false).customOnly, "off")
        val other = custom().apply { aiProvider = "zenmux" }
        check(other.aiCustomOnly && !other.customOnly, "kept, but inert, for another service")
    }

    fun customOnlyDrafts() {
        val fake = Fake({ url, _ -> if (google(url)) googleReply else reply("我们周五发布") })
        val t = Translator(client(fake, custom()), fake)
        t.googleOff = true
        for (i in 0 until 3) equal(null, t.translate("We ship on Friday", "en", "zh-CN", Translator.Kind.Draft), "draft $i shows the original")
        equal(0, fake.sent.size, "partial text goes nowhere: not Google, never the AI service")
        // Off, partial text still never reaches the AI service: only Google.
        t.googleOff = false
        equal("我们周五发布", t.translate("We ship on Friday", "en", "zh-CN", Translator.Kind.Draft), "draft via Google when off")
        check(fake.sent.all { google(it.first) }, "a draft never goes to the AI service")
    }

    fun customOnlySentences() {
        var up = true
        val fake = Fake({ url, _ -> if (google(url)) googleReply else if (up) reply("我们周五发布") else Transport.Response(500, "{}") })
        val t = Translator(client(fake, custom()), fake)
        t.googleOff = true
        equal("我们周五发布", t.translate("We ship on Friday", "en", "zh-CN", Translator.Kind.Sentence), "the service translates")
        check(!t.sentencesUntranslated, "translated")
        up = false
        equal(null, t.translate("We ship on Friday", "en", "zh-CN", Translator.Kind.Sentence), "service down: the original only")
        check(t.sentencesUntranslated, "says the sentence went untranslated")
        check(fake.sent.none { google(it.first) }, "Google is never asked")
        // Off again, Google stands in as before.
        t.googleOff = false
        check(!t.sentencesUntranslated, "flipping forgets the last sentence")
        equal("我们周五发布", t.translate("We ship on Friday", "en", "zh-CN", Translator.Kind.Sentence), "Google stands in when off")
        check(fake.sent.any { google(it.first) }, "Google asked when off")
    }

    fun customOnlyClearsBackoff() {
        var googleUp = false
        val fake = Fake({ url, _ -> if (google(url)) (if (googleUp) googleReply else Transport.Response(429, "")) else reply("") })
        val t = Translator(client(fake, custom(on = false), key = null), fake)
        equal(null, t.translate("Hello", "en", "zh-CN", Translator.Kind.Draft), "Google busy")
        googleUp = true
        val asked = fake.sent.size
        equal(null, t.translate("Hello", "en", "zh-CN", Translator.Kind.Draft), "backing off")
        equal(asked, fake.sent.size, "not asked while backing off")
        t.googleOff = true; t.googleOff = false
        equal("我们周五发布", t.translate("Hello", "en", "zh-CN", Translator.Kind.Draft), "the backoff went with the flip")
    }

    fun shape() {
        for ((id, field, value) in listOf(Triple("ling", "thinking", mapOf("type" to "disabled")),
                                          Triple("zenmux", "reasoning", mapOf("enabled" to false)),
                                          Triple("openrouter", "reasoning", mapOf("enabled" to false)))) {
            val b = mutableMapOf<String, Any?>()
            AppSettings(aiProvider = id).aiConfig().shape(b, 100)
            equal(value, b[field], "$id turns thinking off")
            equal(100, b["max_tokens"], "max_tokens")
            equal(0.2, b["temperature"], "temperature")
        }
        val b = mutableMapOf<String, Any?>()
        AppSettings(aiProvider = "custom", aiCustomBase = "https://x.example/v1").aiConfig().shape(b, 5)
        check("reasoning" !in b && "thinking" !in b, "a custom service gets neither")
        check("chat_template_kwargs" in b, "but the chat template's switch")
    }

    fun audioPart() {
        val wav = byteArrayOf(1, 2, 3)
        equal(mapOf("type" to "audio_url", "audio_url" to mapOf("url" to "data:audio/wav;base64,AQID")),
              AppSettings().aiConfig().audioPart(wav, "Ming-3.0-audio-flash"), "Ming: a data URL")
        val zen = AppSettings(aiProvider = "zenmux").aiConfig()
        equal(mapOf("type" to "input_audio", "input_audio" to mapOf("data" to "AQID", "format" to "wav")),
              zen.audioPart(wav, "google/gemini-3.1-flash-lite"), "input_audio")
        equal("data:audio/wav;base64,AQID", zen.audioPart(wav, "qwen/qwen3.8-omni-flash")["input_audio"].obj()!!["data"], "Qwen: a data URL inside")
    }

    fun catalog() {
        val data = Json.write(mapOf("data" to listOf(
            mapOf("id" to "qwen/qwen3.8-omni-flash", "input_modalities" to listOf("text", "image", "audio", "video"), "output_modalities" to listOf("text")),
            mapOf("id" to "x/asr-only", "input_modalities" to listOf("audio"), "output_modalities" to listOf("text")),
            mapOf("id" to "x/text-model", "architecture" to mapOf("input_modalities" to listOf("text"), "output_modalities" to listOf("text"))),
            mapOf("id" to "x/tts", "input_modalities" to listOf("text"), "output_modalities" to listOf("audio")),
            mapOf("id" to "x/embed-1"),
            mapOf("id" to "google/gemini-3.1-flash-lite:batch", "input_modalities" to listOf("audio", "text"), "output_modalities" to listOf("text")),
        )), pretty = false)
        equal(listOf("rec/one", "qwen/qwen3.8-omni-flash"), Providers.catalog(data, listOf("rec/one"), hears = true), "hear models")
        equal(listOf("qwen/qwen3.8-omni-flash", "x/text-model"), Providers.catalog(data, emptyList(), hears = false), "chat models")
    }

    fun oneKeyFilePerService() {
        val s = AppSettings()
        val k = AIKey(PlainProtector, service = { s.aiProvider })
        k.save("sk-ling-000000000")
        s.aiProvider = "zenmux"
        equal(null, k.read(), "ZenMux has its own")
        check(k.save("sk-zen-0000000000"), "saved")
        equal("ai-key-zenmux", k.path.name, "named as on the Mac")
        val mode = java.nio.file.Files.getPosixFilePermissions(k.path.toPath())
        equal("rw-------", java.nio.file.attribute.PosixFilePermissions.toString(mode), "0600")
        s.aiProvider = "ling"
        equal("sk-ling-000000000", k.read(), "Ling's kept")
        check(!Paths.settings.exists() || !Paths.settings.readText().contains("sk-"), "never in settings")
        k.remove(); s.aiProvider = "zenmux"; k.remove()
    }

    fun localNeedsNoKey() {
        val s = AppSettings(aiProvider = "custom", aiCustomBase = "localhost:11434/v1", aiModels = mutableMapOf("custom" to "qwen3:14b"))
        val ling = client(Fake({ _, _ -> reply("ok") }), s, key = null)
        equal("", ling.currentKey(), "no key needed")
        check(ling.hasKey, "counts as having one")
        s.aiCustomBase = "https://api.example.com/v1"
        check(!ling.hasKey, "a remote one needs a key")
    }

    fun requestShape() {
        val fake = Fake({ _, _ -> reply("LANG: en\nORIGINAL: Hi.\nTRANSLATION: 嗨。", finish = null) })
        val ling = client(fake, AppSettings(aiProvider = "zenmux"))
        // No finish reason: Ling's search essays come without one, other services may just omit it.
        val r = ling.chat("c", "i", Priority.Translate, model = "qwen/qwen3.8-omni-flash", audio = byteArrayOf(1))
        check(r.contains("ORIGINAL: Hi."), "accepted without a finish reason")
        equal("https://zenmux.ai/api/v1/chat/completions", fake.sent[0].first, "url")
        val b = body(fake.sent[0].second)
        equal(mapOf("enabled" to false), b["reasoning"], "reasoning off")
        check("thinking" !in b, "no Ling field")
        equal("input_audio", b["messages"].arr()[1].obj()!!["content"].arr()[0].obj()!!["type"], "input_audio")
        // Text calls use the service's text model.
        ling.chat("c", "i", Priority.Translate)
        equal("inclusionai/ling-3.0-flash", body(fake.sent[1].second)["model"], "text model")
    }

    fun lingDropsNoFinish() {
        val ling = client(Fake({ _, _ -> reply("fine", finish = null) }), AppSettings())
        try { ling.chat("c", "i", Priority.Translate); throw AssertionError("accepted") }
        catch (e: LingException) { equal(LingException.Kind.Hijacked, e.kind, "dropped") }
    }

    fun checkFindsDeafModel() {
        val s = AppSettings(aiProvider = "zenmux", aiHearModels = mutableMapOf("zenmux" to "x/text-only"))
        val ling = client(Fake({ url, b ->
            when {
                url.endsWith("models") -> Transport.Response(200, Json.write(mapOf("data" to listOf(
                    mapOf("id" to "a/b", "input_modalities" to listOf("text"), "output_modalities" to listOf("text")))), pretty = false))
                "input_audio" in b -> Transport.Response(400, "{}")
                else -> reply("OK")
            }
        }), s)
        equal(KeyState.Ok, ling.check(), "the key works")
        equal(false, ling.hears, "the hear model refuses audio")
        equal(AICheck.State.Fail(AICheck.Reason.Deaf, 400), ling.aiCheck[AICheck.StepID.Hear], "deaf at the hear step")
        check(AICheck.isOk(ling.aiCheck[AICheck.StepID.Text]), "the text model still answers")
        check(!ling.canHear, "can't hear")
        check(ling.usable, "notes and translation still work")
        s.aiHearModels.clear()
        ling.keyChanged()
        equal(null, ling.hears, "forgotten")
    }

    fun checkSaysWhy() {
        val bad = client(Fake({ _, _ -> Transport.Response(401, "") }), AppSettings(aiProvider = "zenmux"))
        equal(KeyState.Invalid, bad.check(), "401")
        equal("reach=ok key=fail(invalidKey) text=skipped hear=skipped", bad.aiCheck.summary, "stops at the key")
        val ling = client(Fake({ _, _ -> Transport.Response(404, "") }), AppSettings(aiProvider = "zenmux"))
        ling.check()
        equal(AICheck.Failure(AICheck.StepID.Text, AICheck.Reason.NoModel, 404), ling.aiCheck.failure, "404 is the text model")
        check(ling.checkMessage()!!.contains("inclusionai/ling-3.0-flash"), "names the model")
        equal(KeyState.None, client(Fake({ _, _ -> reply("ok") }), AppSettings(aiProvider = "openrouter"), key = null).keyState, "no key")
    }

    private fun sse(vararg lines: String) = Transport.Stream(200, "text/event-stream", ByteArrayInputStream(lines.joinToString("\n").toByteArray()))

    fun speech() {
        val b64 = Base64.getEncoder()
        val chunk = b64.encodeToString(byteArrayOf(1, 0, 2, 0))
        val fake = Fake({ _, _ -> reply("ok") }, { _, _ -> sse("data: {\"audio\": \"$chunk\"}", "data: {\"type\": \"speech.audio.done\"}") })
        var ling = client(fake, AppSettings(aiProvider = "zenmux"))
        val got = mutableListOf<List<Byte>>()
        ling.speech("Hello", voice = "Puck", language = "ja") { got.add(it.toList()) }
        equal(listOf(listOf<Byte>(1, 0, 2, 0)), got, "SSE base64 chunks")
        val b = body(fake.streamed[0].second)
        equal("https://zenmux.ai/api/v1/audio/speech", fake.streamed[0].first, "url")
        equal(Triple("google/gemini-3.8-flash-tts", "Puck", true), Triple(b["model"], b["voice"], b["stream"]), "body")
        check("language_id" !in b, "language_id is Ling's")
        // A voice that isn't this service's (a Ming name) becomes its first one.
        ling.speech("Hello", voice = "US_Emma") {}
        equal("Kore", body(fake.streamed[1].second)["voice"], "first voice")
        // OpenRouter streams the PCM bytes themselves, without `stream`.
        val raw = Fake({ _, _ -> reply("ok") }, { _, _ -> Transport.Stream(200, "audio/pcm", ByteArrayInputStream(byteArrayOf(5, 0, 6, 0))) })
        ling = client(raw, AppSettings(aiProvider = "openrouter"))
        val pcm = java.io.ByteArrayOutputStream()
        ling.speech("Hi") { pcm.write(it) }
        equal(listOf<Byte>(5, 0, 6, 0), pcm.toByteArray().toList(), "raw PCM")
        check("stream" !in body(raw.streamed[0].second), "no stream for OpenRouter")
        // One JSON with a WAV in it.
        val wav = Wav.bytes(shortArrayOf(7, 8), 24000)
        val one = Fake({ _, _ -> reply("ok") }, { _, _ ->
            Transport.Stream(200, "application/json", ByteArrayInputStream(Json.write(mapOf("audio" to b64.encodeToString(wav))).toByteArray())) })
        ling = client(one, AppSettings(aiProvider = "custom", aiCustomBase = "https://x.example/v1", aiVoiceModels = mutableMapOf("custom" to "kokoro"), aiCustomVoice = "af_heart"))
        val out = java.io.ByteArrayOutputStream()
        ling.speech("Hi", voice = "af_heart") { out.write(it) }
        equal(listOf<Byte>(7, 0, 8, 0), out.toByteArray().toList(), "a WAV in JSON")
        equal(listOf<Byte>(7, 0, 8, 0), LingClient.pcmFromWav(wav).toList(), "pcmFromWav")
    }

    fun noVoiceNoSpeech() {
        val ling = client(Fake({ _, _ -> reply("ok") }), AppSettings(aiProvider = "custom", aiCustomBase = "https://x.example/v1", aiModels = mutableMapOf("custom" to "m")))
        check(!ling.speaks, "no voice model")
        try { ling.speech("Hi") {}; throw AssertionError("spoke") } catch (_: LingException) {}
    }

    fun hearingUsesHearModel() {
        val fake = Fake({ _, _ -> reply("LANG: en\nORIGINAL: We ship on Friday.\nTRANSLATION: 我们周五发布。") })
        val ling = client(fake, AppSettings(aiProvider = "zenmux", aiHearModels = mutableMapOf("zenmux" to "bytedance/doubao-seed-2.0-mini")))
        val heard = Translator(ling).hear(Clip.wav(ShortArray(16000)), "zh-CN", null)
        equal("我们周五发布。", heard?.translation, "translated")
        equal("bytedance/doubao-seed-2.0-mini", body(fake.sent[0].second)["model"], "hear model")
        equal(20.0, Translator.hearTimeout(ling), "slower services get longer")
    }

    fun problemsNameTheService() {
        equal("key", ListenEngine.problem(LingException(LingException.Kind.Http, 400), "ZenMux").first, "a deaf model is a settings problem")
        check(ListenEngine.problem(LingException(LingException.Kind.Network), "ZenMux").second!!.contains("ZenMux"), "named")
        equal("network" to "字幕和纪要等 Ling 恢复 · 连上后自动继续", ListenEngine.problem(LingException(LingException.Kind.Timeout), "Ling"), "what waits and that it goes on")
        equal(null, ListenEngine.problem(LingException(LingException.Kind.Http, 400), "Ling").first, "Ling's 400 is not the model")
        // A gateway's 502 in front of the server: the service erring, not the network or the key.
        equal("busy" to "ZenMux 暂时出错（HTTP 502），稍后再试。", ListenEngine.problem(LingException(LingException.Kind.Http, 502), "ZenMux"), "a 5xx is the service's trouble")
        equal("busy" to "Ling 暂时出错（HTTP 503），稍后再试。", ListenEngine.problem(LingException(LingException.Kind.Http, 503), "Ling"), "Ling's too")
    }

    fun finalNotesRetry() {
        check(LingClient.retryWaits(Priority.Translate).isEmpty(), "translation fails fast")
        equal(listOf(1.0, 2.0, 4.0, 8.0), LingClient.retryWaits(Priority.Translate, audio = true), "heard audio rides out about 15 s")
        equal(listOf(1.0), LingClient.retryWaits(Priority.Speak, audio = true), "what I say retries once")
        equal(listOf(1.0, 2.0, 4.0), LingClient.retryWaits(Priority.Notes), "live notes as before")
        val sum = LingClient.retryWaits(Priority.Notes, patient = true).sum()
        check(sum in 50.0..70.0, "final notes wait about a minute ($sum s)")
    }

    fun clockIsNotSpeech() {
        for (madeUp in listOf("00:00", "00:00.", "1:02:03")) check(Translator.isNoise(madeUp, 1.2), "noise: $madeUp")
        for (said in listOf("Hello.", "3 点", "15%", "好的")) check(!Translator.isNoise(said, 1.2), "kept: $said")
    }

    // MARK: Notes apart (另一个服务)

    private val notesKeys = AIKey(PlainProtector, service = { LingClient.NOTES_KEY })

    /// A custom service at main.example translating with "mt"; notes on "big", at notes.example with `own`.
    private fun notesSettings(own: Boolean) = AppSettings(aiProvider = "custom", aiCustomBase = "https://main.example/v1",
        aiModels = mutableMapOf("custom" to "mt", Providers.NOTES_MODEL to "big"), aiCustomNotesOwn = own,
        aiCustomNotesBase = if (own) "https://notes.example/v1" else "")

    private fun model(body: String) = body(body)["model"]

    fun notesApart() {
        try {
            val fake = Fake({ _, _ -> reply("{}") })
            val ling = client(fake, notesSettings(own = true), key = "sk-main-1111111111")
            check(ling.setNotesKey("sk-notes-222222222"), "notes key saved")
            equal("ai-key-custom-notes", notesKeys.path.name, "named as on the Mac")
            ling.chat("x", "Notes.", Priority.Notes, json = true)
            ling.chat("y", "Translate.", Priority.Translate)
            equal(listOf<Any?>("big", "mt"), fake.sent.map { model(it.second) }, "models")
            equal(listOf("https://notes.example/v1/chat/completions", "https://main.example/v1/chat/completions"), fake.sent.map { it.first }, "servers")
            equal(listOf<String?>("Bearer sk-notes-222222222", "Bearer sk-main-1111111111"), fake.auths, "keys")
            check(!Paths.settings.exists() || !Paths.settings.readText().contains("sk-notes"), "never in settings")
        } finally { notesKeys.remove() }
    }

    fun notesSharedKey() {
        try {
            val fake = Fake({ _, _ -> reply("{}") })
            val ling = client(fake, notesSettings(own = true), key = "sk-main-1111111111")
            ling.chat("x", "Notes.", Priority.Notes)
            equal("https://notes.example/v1/chat/completions", fake.sent[0].first, "their server")
            equal("Bearer sk-main-1111111111", fake.auths[0], "no key of their own: the translation key")
            // The same service, another model: same address and key, even with a notes key file left over.
            notesKeys.save("sk-notes-222222222")
            val same = Fake({ _, _ -> reply("{}") })
            val other = client(same, notesSettings(own = false), key = "sk-main-1111111111")
            other.chat("x", "Notes.", Priority.Notes)
            equal("https://main.example/v1/chat/completions", same.sent[0].first, "translation's server")
            equal("Bearer sk-main-1111111111", same.auths[0], "translation's key")
            equal("big", model(same.sent[0].second), "notes' model")
            // Removing it brings the translation key back.
            val own = client(Fake({ _, _ -> reply("{}") }), notesSettings(own = true), key = "sk-main-1111111111")
            check(own.notesHasOwnKey, "has its own")
            own.removeNotesKey()
            check(!own.notesHasOwnKey, "removed")
            equal("sk-main-1111111111", own.notesKey(), "back to the translation key")
        } finally { notesKeys.remove() }
    }

    fun notesKeyRefused() {
        val fake = Fake({ _, b -> if (model(b) == "big") Transport.Response(401, "{}") else reply("好") })
        val ling = client(fake, notesSettings(own = true), key = "sk-main-1111111111")
        try { ling.chat("x", "Notes.", Priority.Notes); throw AssertionError("accepted") }
        catch (e: LingException) { equal(LingException.Kind.InvalidKey, e.kind, "refused") }
        check(ling.keyState != KeyState.Invalid, "translation's key isn't marked invalid: ${ling.keyState}")
        equal("好", ling.chat("y", "Translate.", Priority.Translate), "translation still works")
        equal(AICheck.Reason.InvalidKey, ling.aiCheck.notes?.reason, "the notes' result says why")
        equal(null, ling.aiCheck.failure, "translation's steps untouched")
        check(ling.aiCheck.notesFailed, "notes failed")
        check(ling.aiCheck.notesLine("notes.example", "big", sharedKey = true)!!.contains("notes.example"), "names the notes server")
        // Refused once: the next notes ask isn't sent.
        val n = fake.sent.size
        try { ling.chat("x", "Notes.", Priority.Notes) } catch (_: LingException) {}
        equal(n, fake.sent.size, "not sent again until settings change")
    }

    fun notesConfig() {
        val plain = AppSettings(aiProvider = "custom", aiCustomBase = "https://main.example/v1", aiModels = mutableMapOf("custom" to "mt")).aiConfig()
        check(!plain.notesApart && plain.forNotes === plain, "not set: the same as translation")
        val model = AppSettings(aiProvider = "custom", aiCustomBase = "https://main.example/v1",
                                aiModels = mutableMapOf("custom" to "mt", Providers.NOTES_MODEL to "big")).aiConfig()
        check(model.notesApart, "another model")
        equal("big", model.forNotes.textModel, "notes' model")
        equal("https://main.example/v1/", model.forNotes.base, "same address")
        equal("https://main.example/v1/", model.forNotes.hearBase, "hearing stays where it was")
        val sameName = AppSettings(aiProvider = "custom", aiCustomBase = "https://main.example/v1",
                                   aiModels = mutableMapOf("custom" to "mt", Providers.NOTES_MODEL to "mt")).aiConfig()
        check(!sameName.notesApart, "the translation model named again is no split")
        // 同一个服务 keeps the typed address, unused.
        val off = notesSettings(own = true).apply { aiCustomNotesOwn = false }.aiConfig()
        equal("https://main.example/v1/", off.forNotes.base, "off: translation's address")
        equal(null, off.notesBase, "off: not used")
        val on = notesSettings(own = true).aiConfig()
        equal("https://notes.example/v1/", on.forNotes.base, "on: their own")
        // Only the custom service splits.
        val ling = AppSettings(aiProvider = "ling", aiModels = mutableMapOf(Providers.NOTES_MODEL to "big")).aiConfig()
        check(!ling.notesApart && ling.forNotes.textModel == ling.textModel, "Ling never splits")
        try {
            notesSettings(own = true).save()
            val back = AppSettings.load()
            check(back.aiCustomNotesOwn, "另一个服务 kept across a restart")
            equal("https://notes.example/v1", back.aiCustomNotesBase, "address kept")
            equal("big", back.aiModels[Providers.NOTES_MODEL], "model kept")
        } finally { Paths.settings.delete() }
    }

    fun notesBadAddress() {
        val s = notesSettings(own = true).apply { aiCustomNotesBase = "http://notes.example/v1" }
        val c = s.aiConfig()
        check(c.notesBadAddress && c.notesApart, "http to the internet can't be used")
        val fake = Fake({ _, _ -> reply("{}") })
        val ling = client(fake, s, key = "sk-main-1111111111")
        try { ling.chat("x", "Notes.", Priority.Notes); throw AssertionError("sent") } catch (_: LingException) {}
        equal(0, fake.sent.size, "not sent to translation's server instead")
        equal("好", client(Fake({ _, _ -> reply("好") }), s, key = "sk-main-1111111111").chat("y", "Translate.", Priority.Translate), "translation works")
    }

    fun notesCheck() {
        try {
            // Notes' server takes no JSON and answers none: their row fails, translation passes.
            val fake = Fake({ url, b ->
                when {
                    url.endsWith("models") -> if ("notes.example" in url) Transport.Response(200, """{"data":[{"id":"big"},{"id":"bigger"}]}""")
                                              else Transport.Response(200, """{"data":[{"id":"other"}]}""")
                    "notes.example" in url -> if ("response_format" in b) Transport.Response(400, "{}") else reply("Sure!")
                    else -> reply("{\"ok\": true}")
                }
            })
            val s = notesSettings(own = true).apply { aiHearModels["custom"] = "omni" }
            val ling = client(fake, s, key = "sk-main-1111111111")
            ling.check()
            val r = ling.aiCheck
            equal(null, r.failure, "translation isn't failed by notes: ${r.summary}")
            check(r[AICheck.StepID.Text] is AICheck.State.Ok, "the sentence proved the text model even though /models doesn't list it")
            equal(AICheck.Reason.NoJSON, r.notes?.reason, "notes: no JSON")
            check(r.passed && r.notesFailed && "notes=fail(noJSON 400)" in r.summary, "summary: ${r.summary}")
            equal(KeyState.Ok, ling.keyState, "the key works")
            equal(listOf("big", "bigger"), ling.notesCatalog, "notes' own list for their menu")
            check(fake.sent.none { "notes.example" in it.first && it.second.contains("Translate the text") }, "the sentence went to translation only")
            // Fixed: notes pass.
            val good = Fake({ url, _ -> if (url.endsWith("models")) Transport.Response(404, "") else reply("{\"ok\": true}") })
            val ok = client(good, s, key = "sk-main-1111111111")
            ok.check()
            check(ok.aiCheck.notes is AICheck.Notes.Ok && !ok.aiCheck.notesFailed, "notes ok: ${ok.aiCheck.summary}")
            // Notes on the same service: no row of their own; the JSON check is translation's.
            val same = client(Fake({ url, _ -> if (url.endsWith("models")) Transport.Response(404, "") else reply("{\"ok\": true}") }),
                              AppSettings(aiProvider = "custom", aiCustomBase = "https://main.example/v1", aiModels = mutableMapOf("custom" to "mt"),
                                          aiHearModels = mutableMapOf("custom" to "omni")), key = "sk-main-1111111111")
            same.check()
            equal(null, same.aiCheck.notes, "no notes row")
        } finally { notesKeys.remove() }
    }

    /// The start gate's time, moved on by each wait instead of waiting.
    private class StepClock : GateClock() {
        var t = 1_000_000L
        override fun now() = t
        override fun wait(lock: Object, ms: Long) { check(ms > 0) { "would wait forever" }; t += ms }
    }

    fun gatePerServer() {
        // Notes' server is out of requests: its 429s pause it, not translation's server.
        val fake = Fake({ url, _ -> if ("notes.example" in url) Transport.Response(429, "", "20") else reply("好") })
        val s = notesSettings(own = true)
        val k = AIKey(PlainProtector, service = { s.aiProvider }).apply { save("sk-main-1111111111") }
        val ling = LingClient(k, fake, config = s::aiConfig, clock = StepClock())
        try { ling.chat("x", "Notes.", Priority.Notes); throw AssertionError("answered") }
        catch (e: LingException) { equal(LingException.Kind.RateLimited, e.kind, "notes gave up") }
        // A translation fails at once while its own server is cooling down; this one isn't.
        equal("好", ling.chat("y", "Translate.", Priority.Translate), "translation starts at once")
        check(ling.keyState != KeyState.Invalid, "key fine")
        // chat_template_kwargs refused by the notes' server only: translation keeps sending it.
        val kw = Fake({ url, b -> if ("notes.example" in url && "chat_template_kwargs" in b) Transport.Response(422, "{}") else reply("{}") })
        val two = client(kw, s, key = "sk-main-1111111111")
        two.chat("x", "Notes.", Priority.Notes)
        two.chat("x", "Notes.", Priority.Notes)
        two.chat("y", "Translate.", Priority.Translate)
        val notes = kw.sent.filter { "notes.example" in it.first }
        equal(3, notes.size, "refused, asked without, then left out")
        check("chat_template_kwargs" !in notes[2].second, "left out at the notes' server")
        check("chat_template_kwargs" in kw.sent.last().second, "translation's server still gets it")
    }
}
