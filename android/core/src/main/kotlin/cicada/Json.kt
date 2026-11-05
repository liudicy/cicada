package cicada

import java.math.BigDecimal

/// A small JSON reader and writer, so the engines need neither org.json (Android only, unsorted)
/// nor a library. Values are Map<String, Any?> (insertion-ordered), List<Any?>, String, Long,
/// Double, Boolean and null.
///
/// `write(pretty = true)` produces what the Mac's JSONEncoder writes with [.prettyPrinted,
/// .sortedKeys], byte for byte: `"key" : value`, two-space indent, `[\n\n  ]` for an empty array,
/// `\/` for a slash, shortest doubles with no ".0", so a record read and written back is unchanged.
object Json {
    class ParseException(message: String) : Exception(message)

    fun parse(text: String): Any? {
        val p = Parser(text)
        p.space()
        val v = p.value()
        p.space()
        if (p.i != text.length) throw ParseException("trailing text at ${p.i}")
        return v
    }

    fun parseObject(text: String): Map<String, Any?>? = try { parse(text) as? Map<String, Any?> } catch (_: ParseException) { null }

    private class Parser(val s: String) {
        var i = 0

        fun space() { while (i < s.length && s[i].isWhitespace()) i++ }

        fun value(): Any? {
            if (i >= s.length) throw ParseException("unexpected end")
            return when (val c = s[i]) {
                '{' -> obj()
                '[' -> arr()
                '"' -> str()
                't' -> word("true", true)
                'f' -> word("false", false)
                'n' -> word("null", null)
                else -> if (c == '-' || c.isDigit()) num() else throw ParseException("unexpected '$c' at $i")
            }
        }

        fun word(w: String, v: Any?): Any? {
            if (!s.startsWith(w, i)) throw ParseException("bad literal at $i")
            i += w.length
            return v
        }

        fun obj(): Map<String, Any?> {
            val m = LinkedHashMap<String, Any?>()
            i++; space()
            if (i < s.length && s[i] == '}') { i++; return m }
            while (true) {
                space()
                if (i >= s.length || s[i] != '"') throw ParseException("expected key at $i")
                val k = str()
                space()
                if (i >= s.length || s[i] != ':') throw ParseException("expected ':' at $i")
                i++; space()
                m[k] = value()
                space()
                if (i >= s.length) throw ParseException("unexpected end")
                if (s[i] == ',') { i++; continue }
                if (s[i] == '}') { i++; return m }
                throw ParseException("expected ',' or '}' at $i")
            }
        }

        fun arr(): List<Any?> {
            val a = ArrayList<Any?>()
            i++; space()
            if (i < s.length && s[i] == ']') { i++; return a }
            while (true) {
                space()
                a.add(value())
                space()
                if (i >= s.length) throw ParseException("unexpected end")
                if (s[i] == ',') { i++; continue }
                if (s[i] == ']') { i++; return a }
                throw ParseException("expected ',' or ']' at $i")
            }
        }

        fun str(): String {
            val b = StringBuilder()
            i++
            while (true) {
                if (i >= s.length) throw ParseException("unterminated string")
                val c = s[i++]
                when (c) {
                    '"' -> return b.toString()
                    '\\' -> {
                        if (i >= s.length) throw ParseException("bad escape")
                        when (val e = s[i++]) {
                            'n' -> b.append('\n'); 't' -> b.append('\t'); 'r' -> b.append('\r')
                            'b' -> b.append('\b'); 'f' -> b.append('\u000C')
                            'u' -> {
                                if (i + 4 > s.length) throw ParseException("bad \\u")
                                b.append(s.substring(i, i + 4).toInt(16).toChar()); i += 4
                            }
                            else -> b.append(e)
                        }
                    }
                    else -> b.append(c)
                }
            }
        }

        fun num(): Any {
            val start = i
            if (s[i] == '-') i++
            while (i < s.length && (s[i].isDigit() || s[i] in ".eE+-")) i++
            val t = s.substring(start, i)
            if (t.none { it == '.' || it == 'e' || it == 'E' }) t.toLongOrNull()?.let { return it }
            return t.toDoubleOrNull() ?: throw ParseException("bad number $t")
        }
    }

    fun write(value: Any?, pretty: Boolean = true): String {
        val b = StringBuilder()
        emit(b, value, pretty, 0)
        return b.toString()
    }

    private fun emit(b: StringBuilder, v: Any?, pretty: Boolean, depth: Int) {
        when (v) {
            null -> b.append("null")
            is String -> quote(b, v)
            is Boolean -> b.append(if (v) "true" else "false")
            is Int, is Long -> b.append(v.toString())
            is Double -> b.append(number(v))
            is Float -> b.append(number(v.toDouble()))
            is Map<*, *> -> {
                // Sorted like Swift's .sortedKeys; nulls are left out, as Swift leaves out nil optionals.
                val entries = v.entries.filter { it.value != null }.sortedBy { it.key as String }
                if (entries.isEmpty()) { b.append(if (pretty) "{\n\n" + "  ".repeat(depth) + "}" else "{}"); return }
                b.append('{')
                entries.forEachIndexed { n, e ->
                    if (n > 0) b.append(',')
                    if (pretty) b.append('\n').append("  ".repeat(depth + 1))
                    quote(b, e.key as String)
                    b.append(if (pretty) " : " else ":")
                    emit(b, e.value, pretty, depth + 1)
                }
                if (pretty) b.append('\n').append("  ".repeat(depth))
                b.append('}')
            }
            is List<*> -> {
                if (v.isEmpty()) { b.append(if (pretty) "[\n\n" + "  ".repeat(depth) + "]" else "[]"); return }
                b.append('[')
                v.forEachIndexed { n, x ->
                    if (n > 0) b.append(',')
                    if (pretty) b.append('\n').append("  ".repeat(depth + 1))
                    emit(b, x, pretty, depth + 1)
                }
                if (pretty) b.append('\n').append("  ".repeat(depth))
                b.append(']')
            }
            else -> quote(b, v.toString())
        }
    }

    /// Shortest round-trip digits, as Swift prints a Double: "2" not "2.0", no exponent for the
    /// values records hold.
    fun number(d: Double): String {
        if (d.isNaN() || d.isInfinite()) return "0"
        if (d == Math.rint(d) && Math.abs(d) < 1e15) return d.toLong().toString()
        val s = d.toString()
        return if (s.contains('E')) BigDecimal(s).stripTrailingZeros().toPlainString() else s
    }

    private fun quote(b: StringBuilder, s: String) {
        b.append('"')
        for (c in s) {
            when (c) {
                '"' -> b.append("\\\"")
                '\\' -> b.append("\\\\")
                '/' -> b.append("\\/")
                '\n' -> b.append("\\n")
                '\r' -> b.append("\\r")
                '\t' -> b.append("\\t")
                '\b' -> b.append("\\b")
                '\u000C' -> b.append("\\f")
                else -> if (c < ' ') b.append(String.format("\\u%04x", c.code)) else b.append(c)
            }
        }
        b.append('"')
    }
}

// Lenient accessors for decoded JSON.

@Suppress("UNCHECKED_CAST")
fun Any?.obj(): Map<String, Any?>? = this as? Map<String, Any?>
fun Any?.arr(): List<Any?> = this as? List<Any?> ?: emptyList()
fun Any?.str(): String? = this as? String
fun Any?.num(): Double? = when (this) {
    is Number -> toDouble()
    is String -> trim().toDoubleOrNull()
    else -> null
}
fun Any?.int(): Int? = num()?.toInt()
fun Any?.bool(): Boolean? = this as? Boolean
