package cicada

import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/// Where the app keeps its files. On Android the app sets `root` to its private filesDir (the dev
/// build has its own app id, so its own folder) and `log` into its cache; tests and the CLI point
/// it at a temp folder, or CICADA_HOME.
object Paths {
    @Volatile var root: File = File(System.getenv("CICADA_HOME") ?: (System.getProperty("java.io.tmpdir") + "/cicada-cli"))
    @Volatile var log: File = File(System.getProperty("java.io.tmpdir"), "cicada-debug.log")
    val sessions get() = File(root, "Sessions")
    val settings get() = File(root, "settings.json")
    val keyFile get() = File(root, "ling-api-key")
}

/// The debug log: timings and states, never meeting text or the key.
object Log {
    private val gate = Any()
    @Volatile var echo = false
    /// Also handed to the platform log (logcat) when set.
    @Volatile var sink: ((String) -> Unit)? = null
    private val clock = object : ThreadLocal<SimpleDateFormat>() {
        override fun initialValue() = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
    }

    fun d(message: String) {
        val line = "${clock.get()!!.format(Date())} $message"
        synchronized(gate) {
            try { Paths.log.appendText(line + "\n") } catch (_: Exception) {}
            if (echo) System.err.println(line)
        }
        sink?.invoke(message)
    }
}

data class Lang(val name: String, val code: String)

/// The languages the Mac app offers (Languages.swift), as translation codes.
object Languages {
    val sources = listOf(
        Lang("English", "en"), Lang("日本語", "ja"), Lang("中文", "zh-CN"), Lang("한국어", "ko"),
        Lang("Español", "es"), Lang("Français", "fr"), Lang("Deutsch", "de"), Lang("Português", "pt"),
    )

    val targets = listOf(
        Lang("简体中文", "zh-CN"), Lang("繁體中文", "zh-TW"), Lang("English", "en"), Lang("日本語", "ja"),
        Lang("한국어", "ko"), Lang("Español", "es"), Lang("Français", "fr"), Lang("Deutsch", "de"), Lang("Português", "pt"),
    )

    /// "Simplified Chinese", "Japanese": the names prompts use.
    fun englishName(code: String): String = when (code) {
        "zh-CN" -> "Simplified Chinese"
        "zh-TW" -> "Traditional Chinese"
        else -> Locale.forLanguageTag(code).getDisplayLanguage(Locale.ENGLISH).ifEmpty { code }
    }

    /// A system UI language ("zh-Hans-CN", "zh-TW", "en-US") as a translation code.
    fun fromSystem(tag: String): String {
        val parts = tag.split('-', '_')
        if (parts[0] != "zh") return parts[0]
        // As the Mac's translationCode: the script decides; a region only when there's none.
        if ("Hant" in parts) return "zh-TW"
        if ("Hans" in parts) return "zh-CN"
        return if (parts.any { it in setOf("TW", "HK", "MO") }) "zh-TW" else "zh-CN"
    }

    /// The Mac's myLanguage: Chinese when the system list has it (the app speaks Chinese),
    /// otherwise the first system language.
    fun myLanguage(prefs: List<String>): String = fromSystem(prefs.firstOrNull { it.startsWith("zh") } ?: prefs.firstOrNull() ?: "zh-Hans")

    /// The Mac's followSystemTarget: my language, unless that is what they speak; then the next
    /// system language, or between Chinese and English when the system has only one.
    fun followSystemTarget(source: String?, prefs: List<String>): String {
        val mine = myLanguage(prefs)
        if (source == null || source != mine) return mine
        return prefs.map(::fromSystem).firstOrNull { it != mine } ?: if (mine.startsWith("zh")) "en" else "zh-CN"
    }

    /// Normalizes what Ming says the language is ("zh", "zh-Hans", "cmn") to a source code.
    fun normalize(reported: String?, fallback: String): String {
        if (reported.isNullOrBlank()) return fallback
        val r = reported.trim().trim('.', '`', '"')
        val head = r.split('-', '_')[0].lowercase()
        if (head == "zh" || head == "cmn" || head == "yue")
            return if (r.contains("TW", ignoreCase = true) || r.contains("Hant", ignoreCase = true)) "zh-TW" else "zh-CN"
        return if (head.length == 2 || head.length == 3) head else fallback
    }

    private fun isCjk(cp: Int) = cp in 0x3040..0x9FFF || cp in 0xAC00..0xD7AF

    private fun count(text: String): Pair<Int, Int> {
        var letters = 0; var cjk = 0
        text.codePoints().forEach { cp ->
            if (Character.isLetter(cp)) { letters++; if (isCjk(cp)) cjk++ }
        }
        return letters to cjk
    }

    /// Whether text is in the target's script: Chinese, Japanese and Korean targets need some CJK,
    /// others must not be mostly CJK (TranslationService.cleanTranslation's check).
    fun inScript(text: String, target: String): Boolean {
        val (letters, cjk) = count(text)
        if (letters == 0) return true
        val wantsCjk = target.startsWith("zh") || target.startsWith("ja") || target.startsWith("ko")
        return if (wantsCjk) cjk > 0 else cjk * 2 <= letters
    }

    /// Notes' check: CJK languages need a fair share (names and numbers stay Latin).
    fun writtenIn(text: String, englishLanguage: String): Boolean {
        val (letters, cjk) = count(text)
        if (letters == 0) return true
        val wantsCjk = listOf("Chinese", "Japanese", "Korean").any { englishLanguage.contains(it) }
        return if (wantsCjk) cjk * 5 >= letters else cjk * 2 < letters
    }

    fun clock(t: Double): String {
        val s = maxOf(0.0, t).toInt()
        return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%02d:%02d".format(s / 60, s % 60)
    }

    /// The same language for speaking purposes: "zh" and "zh-CN" are, "zh-CN" and "zh-TW" aren't.
    fun same(a: String, b: String): Boolean {
        if (a.equals(b, ignoreCase = true)) return true
        val (x, y) = a.substringBefore('-') to b.substringBefore('-')
        return x.equals(y, ignoreCase = true) && (!a.contains('-') || !b.contains('-'))
    }

    fun isCjkLanguage(code: String) = code.startsWith("zh") || code.startsWith("ja") || code.startsWith("ko")
}
