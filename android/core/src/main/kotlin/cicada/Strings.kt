package cicada

import java.util.Locale

/// UI text. The Chinese text is the key, as on the Mac, and the translations are the Mac's own
/// `Resources/{en,ja,ko}.lproj/Localizable.strings` (copied into the APK's assets at build time),
/// plus `Android.strings` for text only the Android app has, and the Mac's
/// `Localizable.stringsdict` for plurals ("1 line", "2 lines"). Placeholders are the Mac's `%@`,
/// filled in order. Never for prompts, logs or stored values.
object Strings {
    @Volatile private var table: Map<String, String> = emptyMap()
    @Volatile private var plurals: Map<String, Plural> = emptyMap()

    /// A stringsdict entry: the format with `%#@n@` placeholders, and each variable's forms by
    /// plural category ("one", "other").
    class Plural(val format: String, val forms: Map<String, Map<String, String>>)
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
        plurals = read("$language.lproj/Localizable.stringsdict")?.let { parsePlurals(it) } ?: emptyMap()
    }

    /// Only English has more than one form among the app's languages: "one" for exactly 1.
    private fun category(n: Any?): String =
        if (language == "en" && (n as? Number)?.toDouble() == 1.0) "one" else "other"

    @JvmStatic fun L(key: String): String = table[key]?.takeIf { it.isNotEmpty() } ?: key

    /// L() with the Mac's placeholders filled in order: `%@` (or `%1$@` by position), and the
    /// numbers `%lld` / `%ld` / `%d`. A key in the stringsdict takes its plural form for the
    /// number: `%#@n@` (or `%2$#@n@`) becomes variable n's "one" or "other" text.
    @JvmStatic fun LF(key: String, vararg args: Any): String {
        val plural = plurals[key]
        val text = plural?.format ?: L(key)
        val b = StringBuilder()
        var next = 0
        var i = 0
        while (i < text.length) {
            if (text[i] != '%' || i + 1 >= text.length) { b.append(text[i]); i++; continue }
            // An optional position: %2$…
            var j = i + 1
            var position: Int? = null
            if (text[j].isDigit() && j + 1 < text.length && text[j + 1] == '$') { position = text[j] - '1'; j += 2 }
            fun arg() = args.getOrNull(position ?: next++)
            if (text.startsWith("#@", j) && plural != null) {
                val end = text.indexOf('@', j + 2)
                if (end > 0) {
                    val n = arg()
                    val forms = plural.forms[text.substring(j + 2, end)] ?: emptyMap()
                    val form = forms[category(n)] ?: forms["other"] ?: ""
                    b.append(form.replace("%lld", "$n").replace("%ld", "$n").replace("%d", "$n"))
                    i = end + 1; continue
                }
            }
            val spec = listOf("@", "lld", "ld", "d").firstOrNull { text.startsWith(it, j) }
            if (spec != null) { b.append(arg() ?: ""); i = j + spec.length; continue }
            b.append(text[i]); i++
        }
        return b.toString()
    }

    /// The Mac's Localizable.stringsdict (an XML plist of dicts and strings) as key → Plural. A
    /// small reader of its own: the XML parsers want to fetch the plist DTD from apple.com.
    fun parsePlurals(xml: String): Map<String, Plural> {
        var i = 0
        fun tag(): String? {
            while (true) {
                val a = xml.indexOf('<', i); if (a < 0) return null
                val e = xml.indexOf('>', a); if (e < 0) return null
                i = e + 1
                val t = xml.substring(a + 1, e).trim()
                if (!t.startsWith("?") && !t.startsWith("!")) return t
            }
        }
        fun text(close: String): String {
            val e = xml.indexOf(close, i).let { if (it < 0) xml.length else it }
            val t = xml.substring(i, e); i = minOf(xml.length, e + close.length)
            return t.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&")
        }
        fun dict(): Map<String, Any> {
            val m = LinkedHashMap<String, Any>()
            while (true) {
                val t = tag() ?: return m
                if (t == "/dict") return m
                if (t != "key") continue
                val k = text("</key>")
                when (tag()) { "dict" -> m[k] = dict(); "string" -> m[k] = text("</string>"); "string/" -> m[k] = "" }
            }
        }
        while (true) { val t = tag() ?: return emptyMap(); if (t == "dict") break }
        val result = HashMap<String, Plural>()
        for ((key, v) in dict()) {
            val entry = v as? Map<*, *> ?: continue
            val format = entry["NSStringLocalizedFormatKey"] as? String ?: continue
            val forms = entry.mapNotNull { (name, d) ->
                (d as? Map<*, *>)?.let { name as String to it.entries.filter { e -> e.value is String }.associate { e -> e.key as String to e.value as String } }
            }.toMap()
            result[key] = Plural(format, forms)
        }
        return result
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
