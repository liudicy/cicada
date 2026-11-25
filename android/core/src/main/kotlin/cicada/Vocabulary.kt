package cicada

import java.io.File
import java.text.Normalizer
import java.time.Instant

/// 词表 (the Mac's Vocabulary.swift): the spellings the user stands behind, and how speech
/// recognition has misheard each. Only these let a new name be fixed without asking: names the
/// notes guess are often wrong, so they stay suggestions until the user confirms one. One JSON
/// file beside the records (`file` null: in memory only). Thread-safe.
class Vocabulary(private val file: File? = Paths.vocabulary) {
    data class Term(
        val word: String,
        /// Wrong forms the recognizer produced, as confirmed or typed by the user.
        val heard: List<String> = emptyList(),
        /// "user" (added or imported), "live" (confirmed during a meeting).
        val source: String,
        val fixes: Int = 0,
        val used: Instant? = null,
    ) {
        fun toJson(): Map<String, Any?> = mapOf("word" to word, "heard" to heard, "source" to source, "fixes" to fixes,
                                                "used" to used?.let(Iso8601::write))
        companion object {
            fun from(o: Map<String, Any?>) = Term(o["word"].str() ?: "", o["heard"].arr().mapNotNull { it.str() },
                                                  o["source"].str() ?: "user", o["fixes"].int() ?: 0, Iso8601.read(o["used"].str()))
        }
    }

    /// What 粘贴导入 did, or would do: added, updated, and the line numbers skipped.
    data class ImportResult(var added: Int = 0, var updated: Int = 0, val skipped: MutableList<Int> = mutableListOf())

    private val gate = Any()
    private var list: List<Term> = emptyList()
    private val listeners = mutableListOf<() -> Unit>()

    init {
        try {
            if (file != null && file.isFile) list = (Json.parse(file.readText()) as? List<*>)?.mapNotNull { it.obj()?.let(Term::from) } ?: emptyList()
        } catch (e: Exception) { Log.d("vocabulary: unreadable (${e.javaClass.simpleName})") }
    }

    val terms: List<Term> get() = synchronized(gate) { list }

    fun onChange(listener: () -> Unit) { synchronized(listeners) { listeners.add(listener) } }

    private fun change(f: (MutableList<Term>) -> Unit) {
        synchronized(gate) {
            val m = list.toMutableList(); f(m)
            if (m == list) return
            list = m.toList()
            save()
        }
        synchronized(listeners) { listeners.toList() }.forEach { it() }
    }

    fun knows(heard: String, word: String): Boolean {
        val h = key(heard); val w = key(word)
        return terms.any { key(it.word) == w && it.heard.any { x -> key(x) == h } }
    }

    /// The user said yes to a fix (or added it): the word, and the form it was heard as. A pair
    /// that isn't a word for a word (`learnable`) adds nothing. A yes in a meeting never teaches a
    /// translation (平台 → platform): it would rewrite that word everywhere after.
    fun confirm(heard: String, word: String, source: String = "live") {
        if (heard.isEmpty()) return add("", word, source)
        val l = learnable(heard, word) ?: return
        if (source != "user" && Correction.translation(l.first, l.second)) return
        add(l.first, l.second, source)
    }

    private fun add(heard: String, word: String, source: String) = change { t ->
        val i = t.indexOfFirst { key(it.word) == key(word) }
        if (i >= 0) {
            if (heard.isNotEmpty() && t[i].heard.none { key(it) == key(heard) }) t[i] = t[i].copy(heard = t[i].heard + heard)
        } else t.add(Term(word, if (heard.isEmpty()) emptyList() else listOf(heard), source))
    }

    /// A heard form the user turned down twice stops being one.
    fun forget(heard: String, word: String) = change { t ->
        val i = t.indexOfFirst { key(it.word) == key(word) }
        if (i >= 0) t[i] = t[i].copy(heard = t[i].heard.filter { key(it) != key(heard) })
    }

    /// 词表 › tap a word: its spelling changes; what it was heard as stays with it.
    fun rename(word: String, new: String) = change { t ->
        val n = new.trim()
        val i = t.indexOfFirst { key(it.word) == key(word) }
        if (n.isEmpty() || n.length > 40 || i < 0) return@change
        val j = t.indexOfFirst { key(it.word) == key(n) }
        if (j >= 0 && j != i) {
            // Renamed onto a word already there: the two become one.
            t[j] = t[j].copy(heard = t[j].heard + t[i].heard.filter { h -> t[j].heard.none { key(it) == key(h) } })
            t.removeAt(i)
        } else t[i] = t[i].copy(word = n)
    }

    /// The other words a heard form already belongs to ("莫拉" is Morpho's).
    fun owners(heard: String, except: String? = null): List<String> =
        terms.filter { t -> t.heard.any { key(it) == key(heard) } && key(t.word) != key(except ?: "") }.map { it.word }

    /// Back where it was, after 撤销 on a delete.
    fun insert(term: Term, at: Int) = change { t ->
        if (t.none { key(it.word) == key(term.word) }) t.add(minOf(at, t.size), term)
    }

    /// 撤销: the list as it was.
    fun restore(saved: List<Term>) = change { t -> t.clear(); t.addAll(saved) }

    fun remove(word: String) = change { t -> t.removeAll { key(it.word) == key(word) } }

    fun used(word: String, at: Instant = Instant.now()) = change { t ->
        val i = t.indexOfFirst { key(it.word) == key(word) }
        if (i >= 0) t[i] = t[i].copy(fixes = t[i].fixes + 1, used = at)
    }

    /// For the request: the most recently useful first, "Morpho (heard as 莫拉, 莫法)".
    fun promptLines(): List<String> =
        terms.sortedByDescending { it.used ?: Instant.EPOCH }.take(LIMIT).map {
            if (it.heard.isEmpty()) it.word else "${it.word} (heard as ${it.heard.joinToString(", ")})"
        }

    /// What 粘贴导入 would do, before it does it (the dialog's counts and its button).
    fun preview(text: String): ImportResult {
        val r = ImportResult()
        val seen = HashSet<String>()
        val t = terms
        for (e in parse(text)) {
            if (e.word.isEmpty()) { r.skipped.add(e.line); continue }
            val k = key(e.word)
            if (t.any { key(it.word) == k } || k in seen) r.updated++ else r.added++
            seen.add(k)
        }
        return r
    }

    fun importText(text: String): ImportResult {
        val r = ImportResult()
        change { t ->
            for (e in parse(text)) {
                if (e.word.isEmpty()) { r.skipped.add(e.line); continue }
                val i = t.indexOfFirst { key(it.word) == key(e.word) }
                if (i >= 0) {
                    t[i] = t[i].copy(heard = t[i].heard + e.heard.filter { h -> t[i].heard.none { key(it) == key(h) } }.distinctBy(::key))
                    r.updated++
                } else {
                    t.add(Term(e.word, e.heard, "user"))
                    r.added++
                }
            }
        }
        return r
    }

    private fun save() {
        val f = file ?: return
        try {
            f.parentFile?.mkdirs()
            val tmp = File(f.path + ".tmp")
            tmp.writeText(Json.write(list.map { it.toJson() }))
            if (!tmp.renameTo(f)) { f.delete(); tmp.renameTo(f) }
        } catch (e: Exception) { Log.d("vocabulary: save failed ${e.javaClass.simpleName}") }
    }

    class Entry(val line: Int, val word: String, val heard: List<String>)

    companion object {
        /// More would make every sentence's request long, and more terms means more wrong swaps.
        const val LIMIT = 300

        /// What a fix can teach the list, or null: both sides trimmed of spaces and punctuation, no
        /// punctuation inside, short, and a real swap. An edit that only adds or drops words around
        /// the heard ones ("我来" → "OK我来") or ends on a full stop ("持。" → "讲。") teaches nothing.
        fun learnable(heard: String, word: String): Pair<String, String>? {
            val h = trimEdges(heard); val w = trimEdges(word)
            if (h.isEmpty() || w.isEmpty() || h.codePointCount(0, h.length) > 20 || w.codePointCount(0, w.length) > 40 || key(h) == key(w)) return null
            if (w.contains(h) || h.contains(w)) return null
            if (h.codePoints().anyMatch { punctuation(it) }) return null
            if (w.codePoints().anyMatch { punctuation(it) && it != '.'.code && it != '-'.code }) return null
            return h to w
        }

        private fun punctuation(c: Int): Boolean = when (Character.getType(c).toByte()) {
            Character.CONNECTOR_PUNCTUATION, Character.DASH_PUNCTUATION, Character.START_PUNCTUATION, Character.END_PUNCTUATION,
            Character.INITIAL_QUOTE_PUNCTUATION, Character.FINAL_QUOTE_PUNCTUATION, Character.OTHER_PUNCTUATION -> true
            else -> false
        }

        /// Spaces, punctuation and symbols: what a learned pair is trimmed of at both ends.
        private fun edge(c: Int): Boolean = Character.isWhitespace(c) || Character.isSpaceChar(c) || punctuation(c) ||
            when (Character.getType(c).toByte()) {
                Character.MATH_SYMBOL, Character.CURRENCY_SYMBOL, Character.MODIFIER_SYMBOL, Character.OTHER_SYMBOL -> true
                else -> false
            }

        private fun trimEdges(s: String): String {
            var a = 0; var b = s.length
            while (a < b && edge(s.codePointAt(a))) a += Character.charCount(s.codePointAt(a))
            while (b > a && edge(s.codePointBefore(b))) b -= Character.charCount(s.codePointBefore(b))
            return s.substring(a, b)
        }

        /// Same word whatever its width, case or spacing ("ＡＡＶＥ" is "aave").
        fun key(s: String): String = Normalizer.normalize(s, Normalizer.Form.NFKC).lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")

        /// 粘贴导入: one per line, heard forms after "=" ("Morpho = 莫拉、莫法"). A line too long (or
        /// with control characters) comes back with an empty word, reported by its number.
        fun parse(text: String): List<Entry> = text.split(Regex("\r\n|\r|\n")).mapIndexedNotNull { i, raw ->
            val line = raw.trim()
            if (line.isEmpty()) return@mapIndexedNotNull null
            val parts = line.split("=", limit = 2).map { it.trim() }
            val word = parts[0]
            val heard = if (parts.size > 1) parts[1].split(Regex("[、,，;；]")).map { it.trim() }.filter { it.isNotEmpty() } else emptyList()
            if (word.isEmpty() || word.codePointCount(0, word.length) > 40 || word.any { Character.isISOControl(it) }) Entry(i + 1, "", emptyList())
            else Entry(i + 1, word, heard)
        }
    }
}
