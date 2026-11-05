package cicada

import java.util.Locale

/// UI text. The Chinese text is the key, as on the Mac, and the translations are the Mac's own
/// `Resources/{en,ja,ko}.lproj/Localizable.strings` (copied into the APK's assets at build time),
/// plus `Android.strings` for text only the Android app has. Placeholders are the Mac's `%@`,
/// filled in order. Never for prompts, logs or stored values.
object Strings {
    @Volatile private var table: Map<String, String> = emptyMap()
    @Volatile var language = "zh-Hans"; private set

    val locale: Locale get() = when (language) {
        "en" -> Locale.ENGLISH; "ja" -> Locale.JAPANESE; "ko" -> Locale.KOREAN; else -> Locale.SIMPLIFIED_CHINESE
    }

    /// Loads the table for `ui` ("en", "ja", "ko"; anything else is Chinese). `read` returns the
    /// text of "<lang>.lproj/<name>" or null.
    fun load(ui: String, read: (String) -> String?) {
        val head = ui.split('-', '_')[0]
        language = if (head == "en" || head == "ja" || head == "ko") head else "zh-Hans"
        val t = HashMap<String, String>()
        // The Mac's table, then the Android-only strings over it (same format).
        for (name in listOf("Localizable.strings", "Android.strings")) {
            read("$language.lproj/$name")?.let { t.putAll(parse(it)) }
        }
        table = t
    }

    @JvmStatic fun L(key: String): String = table[key]?.takeIf { it.isNotEmpty() } ?: key

    /// L() with the Mac's placeholders filled in order: `%@` (or `%1$@` by position), and the
    /// numbers `%lld` / `%ld` / `%d`.
    @JvmStatic fun LF(key: String, vararg args: Any): String {
        val text = L(key)
        val b = StringBuilder()
        var next = 0
        var i = 0
        while (i < text.length) {
            if (text[i] == '%' && i + 1 < text.length && text[i + 1] == '@') {
                b.append(args.getOrNull(next++) ?: ""); i += 2; continue
            }
            val number = listOf("%lld", "%ld", "%d").firstOrNull { text.startsWith(it, i) }
            if (number != null) { b.append(args.getOrNull(next++) ?: ""); i += number.length; continue }
            if (text[i] == '%' && i + 3 < text.length && text[i + 1].isDigit() && text[i + 2] == '$' && text[i + 3] == '@') {
                b.append(args.getOrNull(text[i + 1] - '1') ?: ""); i += 4; continue
            }
            b.append(text[i]); i++
        }
        return b.toString()
    }

    /// `"key" = "value";` lines, with /* */ and // comments and \" \\ \n escapes.
    fun parse(text: String): Map<String, String> {
        val result = HashMap<String, String>()
        var i = 0
        fun readString(): String? {
            while (i < text.length) {
                if (text[i] == '"') break
                if (text.startsWith("/*", i)) { val e = text.indexOf("*/", i + 2); i = if (e < 0) text.length else e + 2; continue }
                if (text.startsWith("//", i)) { val e = text.indexOf('\n', i); i = if (e < 0) text.length else e + 1; continue }
                i++
            }
            if (i >= text.length) return null
            i++
            val b = StringBuilder()
            while (i < text.length && text[i] != '"') {
                if (text[i] == '\\' && i + 1 < text.length) {
                    i++
                    b.append(when (text[i]) { 'n' -> '\n'; 't' -> '\t'; else -> text[i] })
                } else b.append(text[i])
                i++
            }
            i++
            return b.toString()
        }
        while (true) {
            val key = readString() ?: break
            val value = readString() ?: break
            result[key] = value
        }
        return result
    }
}
