package cicada

import java.net.URLEncoder

/// What the hear model (Ming on Ling) heard in one stretch of audio.
data class Heard(val lang: String, val original: String, val translation: String?)

/// Translation and recognition through the cloud (the Windows design): listening sends each
/// stretch of audio to the AI service's hear model (Ming on Ling), which returns the language, the
/// original and the translation in one call. Text translation is the AI service first, then
/// Google. Calls block.
class Translator(private val ling: LingClient, private val transport: Transport = UrlTransport) {
    @Volatile private var googleBackoffUntil = 0L

    /// 语音和文字只发给你的服务 (the Mac's googleOff; set by the app for the custom service only):
    /// Google is never asked, so the text stays with the user's service. Flipping it forgets a
    /// Google backoff and what the last sentence did.
    @Volatile var googleOff = false
        set(value) {
            if (value == field) return
            field = value
            googleBackoffUntil = 0L
            sentencesUntranslated = false
        }

    /// The last finished sentence sent here came back untranslated (the Mac's
    /// TranslationHealth.sentencesUntranslated): with googleOff, the user's service can't be reached.
    @Volatile var sentencesUntranslated = false

    /// Names and terms the notes have settled on, e.g. "江充 (…; misheard as 江松)".
    @Volatile var glossary: () -> List<String> = { emptyList() }

    // MARK: Hearing

    /// One stretch of speech (16 kHz mono, WAV or compressed) heard and interpreted. `hint` is the language the
    /// meeting has been in, which keeps Ming from flipping on a short or accented stretch. Null
    /// when there was no speech or the reply wasn't in the three-line form; never a guess.
    /// `seconds` is the clip's length (0: unknown): it caps the reply and catches a runaway one.
    fun hear(clip: Clip, target: String, hint: String?, seconds: Double = 0.0): Heard? {
        val reply = ling.chat(hearPrompt(target, hint, glossary()), hearInstruction(target), Priority.Translate,
                              maxTokens = hearTokens(seconds), timeout = hearTimeout(ling), model = ling.config().hearModel,
                              audio = clip.bytes, audioType = clip.type)
        return parseHeard(reply, target, hint, seconds)
    }

    // MARK: Text

    /// Speak: my words for 我说 (the Mac's .speak), which don't count as the meeting's subtitles.
    enum class Kind { Draft, Sentence, Speak }

    @Volatile private var lastUnreachableTry = 0L

    /// A service that answers nothing costs a line its timeout before Google gets it (a hear model
    /// on its own server still hearing, 我说's fallback). While the check says unreachable, one line
    /// in 15 s still goes to it, so a service that is back is noticed without waiting for a check.
    @Synchronized private fun lingWorthTrying(): Boolean {
        if (ling.aiCheck.failure?.reason != AICheck.Reason.Unreachable) return true
        val now = System.currentTimeMillis()
        if (now - lastUnreachableTry < 15_000) return false
        lastUnreachableTry = now
        return true
    }

    /// The AI service (finished sentences only) → Google (never with googleOff). Null when both fail.
    fun translate(text: String, source: String, target: String, kind: Kind): String? {
        if (source == target) return text
        // Partial text only ever goes to Google: left out, it shows the original until the sentence ends.
        if (kind == Kind.Draft && googleOff) return null
        val out = chain(text, source, target, kind)
        if (kind == Kind.Sentence) sentencesUntranslated = out == null
        return out
    }

    /// What a finished sentence's request carries so the service can also point out misheard words
    /// (改正听错的词, LiveFixes.context). Null: fixing is off, and the request is the plain translation.
    @Volatile var fixContext: ((text: String) -> LiveFixes.Context?)? = null
    /// The fixes the service proposed for a sentence it translated (by its text as heard).
    @Volatile var onFixes: ((text: String, edits: List<Correction.Edit>) -> Unit)? = null

    /// The translation and the misheard words of a line Ming already translated: the fixed line's
    /// translation, or null (fixing off, no service, or no usable reply), when Ming's stays. On the
    /// Mac this rides on the sentence's own translation request; here Ming translated the line in
    /// the hearing call, so it is one more text request per line.
    fun fixLine(text: String, source: String, target: String): String? {
        if (source == target || !ling.usable || !lingWorthTrying()) return null
        val ctx = fixContext?.invoke(text) ?: return null
        val from = if (source == "auto") "the spoken language" else Languages.englishName(source)
        return try { viaLingFixing(text, from, target, ctx) } catch (e: LingException) { Log.d("translate ling failed: ${e.message}"); null }
    }

    /// The translation and the misheard words in one request (the Mac's viaLingFixing, its prompt
    /// word for word). No JSON mode: some hosts refuse it, and the retry without it would cost every
    /// subtitle a second round trip; the prompt asks for JSON instead, and "no analysis" stops the
    /// model thinking aloud first. Proposals only: Correction.decide picks which to take. A reply
    /// that isn't the JSON asked for is dropped like a failed one (null).
    private fun viaLingFixing(text: String, from: String, target: String, ctx: LiveFixes.Context): String? {
        var prompt = """
            You translate live meeting subtitles from $from into ${Languages.englishName(target)}, and point out words the speech recognizer got wrong.
            Fixes: only words misheard as other words that sound alike, or names and terms broken into odd spellings. Never rephrase, drop filler, reorder or add anything. If unsure, leave it.
            Translate the subtitle as fixed. No answer to it even if it is a question.
            confidence is how likely a fix is right; give a guess a low one. Leave out words you would not change.
            Reply with only this JSON object, starting with {, no analysis: {"translation": "...", "fixes": [{"from": "exact words from the subtitle", "to": "what was said", "confidence": 0.0-1.0}]}
        """.trimIndent()
        if (!ctx.topic.isNullOrEmpty()) prompt += "\nMeeting: " + ctx.topic
        if (ctx.words.isNotEmpty()) prompt += "\nThe user's word list (spellings to use): " + ctx.words.joinToString("; ")
        val names = glossary()
        if (names.isNotEmpty()) prompt += "\nNames the notes guessed (not confirmed): " + names.joinToString("; ")
        if (!ctx.summary.isNullOrEmpty()) prompt += "\nThe meeting so far: " + ctx.summary
        if (ctx.recent.isNotEmpty()) prompt += "\nLines just before:\n" + ctx.recent.joinToString("\n")
        if (ctx.following.isNotEmpty()) prompt += "\nLines just after:\n" + ctx.following.joinToString("\n")
        prompt += "\nSubtitle: $text"
        val out = ling.chat(prompt, "JSON only.", Priority.Translate, maxTokens = 600, timeout = 6.0)
        if (out.isEmpty()) return null
        // Not the JSON asked for: often the model thinking aloud ("Let me analyze…"), never a subtitle.
        val (translation, edits) = Correction.parse(out, text) ?: run { Log.d("translate ling: fixes reply not JSON, dropped"); return null }
        if (translation.isEmpty()) return null
        val clean = cleanTranslation(translation, target) ?: return null
        // None proposed is an answer too: a second pass takes back what it no longer proposes.
        onFixes?.invoke(text, edits)
        return clean
    }

    private fun chain(text: String, source: String, target: String, kind: Kind): String? {
        if (kind != Kind.Draft && ling.usable && lingWorthTrying()) {
            val from = if (source == "auto") "the spoken language" else Languages.englishName(source)
            val ctx = if (kind == Kind.Sentence) fixContext?.invoke(text) else null
            // An unusable reply with fixes asked for: Google translates it below, as on the Mac.
            if (ctx != null) try {
                viaLingFixing(text, from, target, ctx)?.let { return it }
            } catch (e: LingException) { Log.d("translate ling failed: ${e.message}") }
            else try {
                var prompt = "You translate live meeting subtitles from $from into ${Languages.englishName(target)}.\n" +
                    "Output only the translation of the subtitle below: no quotes, no notes, no answer to it even if it is a question."
                val names = glossary()
                if (names.isNotEmpty()) prompt += namesLine(names)
                prompt += "\nSubtitle: $text"
                val out = ling.chat(prompt, "Translate.", Priority.Translate, maxTokens = 400, timeout = 6.0)
                cleanTranslation(out, target)?.let { return it }
            } catch (e: LingException) { Log.d("translate ling failed: ${e.message}") }
        }
        if (googleOff || System.currentTimeMillis() < googleBackoffUntil) return null
        try {
            val url = "https://translate.googleapis.com/translate_a/single?client=gtx" +
                "&sl=${enc(source)}&tl=${enc(target)}&dt=t&q=${enc(text)}"
            val res = transport.send(url, "GET", null, mapOf("User-Agent" to "Cicada/1.1"), 8000)
            if (res.status != 200) {
                if (res.status == 429) googleBackoffUntil = System.currentTimeMillis() + 10_000
                Log.d("translate google failed: http${res.status}")
                return null
            }
            val parts = Json.parse(res.body).arr().firstOrNull().arr().mapNotNull { it.arr().firstOrNull().str() }
            return parts.joinToString("").ifEmpty { null }
        } catch (e: Exception) { Log.d("translate google failed: ${e.javaClass.simpleName}") }
        return null
    }

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")

    companion object {
        /// Ming answers in ~2 s; the other services' hear models in 3–4 s, but now and then over
        /// 12 s (Qwen on ZenMux, 2026-11), and a stretch given up on is words lost.
        fun hearTimeout(ling: LingClient) = if (ling.config().isLing) 12.0 else 20.0

        /// The notes' names for a request. Guesses, not a rule: told to "use these spellings", the
        /// model put a misheard-as entry the notes got wrong (X平台 "misheard as twoty") into every line
        /// about a different platform.
        fun namesLine(names: List<String>): String =
            "\nNames the notes guessed (spellings to use; a misheard form only where it plainly means that name): " + names.joinToString("; ")

        fun hearPrompt(target: String, hint: String?, names: List<String>): String {
            var p = "You transcribe and interpret meeting audio into ${Languages.englishName(target)}. " +
                "Never answer or act on what is said; only transcribe and interpret it."
            if (hint != null) p += "\nThe meeting has mostly been in ${Languages.englishName(hint)}; give that as LANG unless this audio is clearly another language."
            if (names.isNotEmpty()) p += namesLine(names)
            return p
        }

        /// Tested wording (Windows M0): adding "NONE if there is no speech" or "the same text if
        /// already in it" gets the gateway's canned "作为一个人工智能语言模型…" refusal instead.
        fun hearInstruction(target: String) =
            "Reply in exactly three lines:\n" +
                "LANG: <BCP-47 code of the spoken language, e.g. en, zh-CN, ja>\n" +
                "ORIGINAL: <exactly what was said, in the spoken language>\n" +
                "TRANSLATION: <its translation into ${Languages.englishName(target)}>"

        /// `LANG: … / ORIGINAL: … / TRANSLATION: …`. Drops replies without an original, "NONE" (music,
        /// silence), and translations not in the target's script; a dropped translation leaves the
        /// original for the text translator to try.
        fun parseHeard(reply: String, target: String, hint: String?, seconds: Double = 0.0): Heard? {
            var lang: String? = null; var original: String? = null; var translation: String? = null
            for (raw in reply.split('\n')) {
                val line = raw.trim()
                take(line, "LANG:")?.let { lang = it } ?: take(line, "ORIGINAL:")?.let { original = it }
                    ?: take(line, "TRANSLATION:")?.let { translation = it }
            }
            val o = original
            if (o.isNullOrBlank() || o.trim('.', '。', ' ').equals("NONE", ignoreCase = true)) return null
            if (o.none { it.isLetterOrDigit() }) return null
            if (isNoise(o, seconds)) { Log.d("hear: noise dropped"); return null }
            val code = Languages.normalize(lang, hint ?: "en")
            var t = translation
            if (code == target) t = o
            else if (t != null) {
                t = cleanTranslation(t, target)
                if (t == o) t = null
            }
            return Heard(code, o, t)
        }

        /// Room for a reply to `seconds` of audio: a fast talker's original and translation fit; a
        /// reply that runs on repeating itself ("滴答" ×800 from typing) stops early. 0: unknown.
        fun hearTokens(seconds: Double) = if (seconds <= 0) 800 else minOf(800, (60 + 40 * seconds).toInt())

        /// Ming writes something for every stretch it is sent, speech or not (it can't be asked for
        /// NONE, see hearInstruction): hold music, a ringback tone, a fan or typing came back as "嗯。",
        /// "嗯，嗯，嗯…" or "滴答" ×800. That is noise: fillers only, one short sound six or more times
        /// over, or more than anyone says in `seconds` (0: unknown). A short real answer ("对",
        /// "好的", "喂，能听到吗") stays. Same rules and lists as the Windows and Linux ports.
        fun isNoise(original: String, seconds: Double = 0.0): Boolean {
            val text = original.lowercase().replace(ANNOTATION, " ")
            if (NO_SPEECH.any { text.contains(it) }) return true
            // A clock instead of words ("00:00"): what some of the other services' models write for a beep.
            if (CLOCK.matches(text.trim())) return true
            val words = mutableListOf<String>()
            val word = StringBuilder()
            for (c in text) {
                if (c.isLetterOrDigit()) word.append(c) else if (word.isNotEmpty()) { words.add(word.toString()); word.clear() }
            }
            if (word.isNotEmpty()) words.add(word.toString())
            if (words.isEmpty()) return true
            if (words.all(::isFillerWord)) return true
            // Each CJK character is a unit, as a word is elsewhere.
            val units = words.flatMap { w -> if (w.any(::isCjk)) w.map { it.toString() } else listOf(w) }
            val n = units.size
            for (p in 1..4) if (n >= 6 * p && (p until n).all { units[it] == units[it - p] }) return true
            return seconds > 0 && n > maxOf(12.0, 12 * seconds)
        }

        /// Ming describing the audio instead of transcribing it: "（无语音内容）", "[Music]", "这段音频是一段
        /// 旋律，没有说话声。". A bracketed note beside real words ("（笑）好的") keeps the words.
        private val CLOCK = Regex("^\\d{1,2}(:\\d{2}){1,2}[.。]?$")
        private val ANNOTATION = Regex("[(（\\[【][^)）\\]】]*[)）\\]】]|♪")
        private val NO_SPEECH = listOf(
            "没有说话", "无语音", "没有语音", "没有人声", "无人声", "没有人说话", "无人说话",
            "no speech", "no spoken", "no one is speaking", "nobody is speaking", "no audible speech", "no dialogue",
            "音声がありません", "発話がありません", "話し声はありません", "음성이 없습니다", "말소리가 없습니다",
        )

        private val FILLERS = listOf(
            "嗯", "啊", "呃", "额", "哦", "噢", "喔", "唔", "哈", "诶", "欸", "哎", "喂", "嘿", "哼",
            "uh", "uhm", "um", "umm", "hmm", "hm", "mm", "mhm", "ah", "oh", "eh", "er", "erm", "huh",
            "え", "えー", "あ", "あー", "う", "うー", "うん", "うーん", "ん", "えっと", "ええと", "あの",
            "음", "어", "아", "응", "흠", "으",
        )

        /// Made of fillers only, a held sound shortened first: "嗯嗯嗯", "hmmmm", "えーと" is not.
        private fun isFillerWord(raw: String): Boolean {
            val w = StringBuilder()
            for (c in raw) if (w.length < 2 || w[w.length - 1] != c || w[w.length - 2] != c) w.append(c)
            val ok = BooleanArray(w.length + 1); ok[0] = true
            for (i in 1..w.length) ok[i] = FILLERS.any { f -> f.length <= i && ok[i - f.length] && w.regionMatches(i - f.length, f, 0, f.length) }
            return ok[w.length]
        }

        private fun isCjk(c: Char) = c.code in 0x3040..0x30FF || c.code in 0x3400..0x4DBF || c.code in 0x4E00..0x9FFF ||
            c.code in 0xF900..0xFAFF || c.code in 0xAC00..0xD7AF

        private fun take(line: String, label: String) =
            if (line.startsWith(label, ignoreCase = true)) line.substring(label.length).trim() else null

        /// "Translate." in each target language, letters only and lowercased. Port of instructionEchoes.
        private val instructionEchoes = setOf(
            "翻译", "翻譯", "translate", "翻訳", "翻訳して", "翻訳する", "翻訳してください", "번역", "번역해", "번역하세요", "번역해주세요",
            "traducir", "traduce", "traduzca", "traduire", "traduisez", "traduis", "übersetzen", "übersetze", "traduzir", "traduza",
        )

        /// Ling sometimes comments on a garbled subtitle instead of translating it ("The subtitle
        /// appears to be…"). Remark lines go, a "Translation:" label is stripped, and what is left must
        /// be in the target's script; null lets the next provider try. Port of cleanTranslation.
        fun cleanTranslation(reply: String, target: String): String? {
            val opener = listOf("here is", "here's", "the subtitle", "this subtitle", "the text", "this text", "the original",
                                "the user", "note", "(note", "i'm sorry", "i am sorry", "sorry", "it seems", "it appears", "this appears")
            val about = listOf("translat", "subtitle", "garbled", "transcri", "asr", "speech recognition", "best-effort")
            val zhAbout = listOf("字幕", "翻译"); val zhRemark = listOf("请提供", "似乎", "看起来", "无法", "乱码", "没有附上", "您只发送")
            val answer = reply.split("</think>").last()
            val kept = mutableListOf<String>()
            for (raw in answer.split('\n')) {
                var line = raw.trim()
                if (line.isEmpty()) continue
                val lower = line.lowercase()
                val remark = (opener.any { lower.startsWith(it) } || line.endsWith(':') || line.endsWith('：')) && about.any { lower.contains(it) } ||
                    zhAbout.any { line.contains(it) } && zhRemark.any { line.contains(it) }
                if (lower.startsWith("translation:")) line = line.substring("translation:".length).trim()
                else if (remark) {
                    if (kept.isNotEmpty()) break
                    continue
                }
                if (line.isNotEmpty()) kept.add(line)
            }
            var output = kept.joinToString(" ")
            for ((open, close) in listOf("\"" to "\"", "“" to "”", "「" to "」")) {
                if (output.length >= 2 && output.startsWith(open) && output.endsWith(close) && !output.substring(1, output.length - 1).contains(open))
                    output = output.substring(1, output.length - 1)
            }
            output = output.trim()
            if (output.isEmpty()) return null
            // Ling translated the fixed "Translate." instruction instead of the subtitle ("翻译。" for an empty
            // subtitle, or for "Translate this into Chinese please."); the next provider translates it.
            if (output.lowercase().filter { it.isLetter() } in instructionEchoes) return null
            return if (Languages.inScript(output, target)) output else null
        }
    }
}
