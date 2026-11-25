package cicada

/// A word the AI service said speech recognition got wrong in a finished line ("莫拉" → "Morpho"),
/// field for field the Mac's LineFix. The line keeps what was heard (`src`) and carries its fixes,
/// so a record moves between the platforms unchanged.
data class LineFix(
    var from: String,
    var to: String,
    /// Waiting for the user (a name sound can't check): not applied until confirmed.
    var ask: Boolean? = null,
    /// The user said no (改回 or 不对): kept so the same line isn't fixed that way again.
    var off: Boolean? = null,
    /// The user's own: said 对, or wrote it (改这句…). A later pass never drops or overrides it.
    var user: Boolean? = null,
) {
    val applied: Boolean get() = ask != true && off != true

    fun toJson(): Map<String, Any?> = mapOf("from" to from, "to" to to, "ask" to ask, "off" to off, "user" to user)

    companion object {
        fun from(o: Map<String, Any?>) = LineFix(o["from"].str() ?: "", o["to"].str() ?: "", o["ask"].bool(), o["off"].bool(), o["user"].bool())
    }
}

/// 改正听错的词 (the Mac's Correction.swift): which of the service's proposed fixes to take, and
/// the line as shown once they are in. The service's own confidence isn't enough: in a 21-minute
/// test it rated "快销 → 区块" and "苍蝇 → 方向" above 0.85. So a Chinese word may only be swapped
/// for one that sounds alike (pinyin), a Latin word only for a near spelling, and a new name only
/// once the user says so.
object Correction {
    data class Edit(val from: String, val to: String, val confidence: Double)

    enum class Verdict { Apply, Ask, Drop }

    const val APPLY_AT = 0.6
    const val SPELLING_AT = 0.8
    const val ASK_AT = 0.8

    /// Toneless lowercase pinyin of one character ("" when it has none). The app sets the phone's
    /// ICU transform ("Han-Latin; Latin-ASCII"), the counterpart of the Mac's system transform;
    /// the tests and the CLI set a table generated from the same transform. Unset: nothing sounds alike.
    @Volatile var pinyinOf: (Char) -> String = { "" }

    private fun word(c: Char) = c.code < 128 && c.isLetterOrDigit()

    /// The part an edit changes, as a word: "解除质压" → "解除质押" is "质压" → "质押" (at least two
    /// characters, so one refusal doesn't block every 压 → 押), and a Latin word stays whole
    /// ("Un450P三" → "Uniswap V3", not "450P三" → "iswap V3").
    fun core(from: String, to: String): Pair<String, String> {
        val a = from; val b = to
        var i = 0
        while (i < minOf(a.length, b.length) && a[i] == b[i]) i++
        var j = 0
        while (j < minOf(a.length, b.length) - i && a[a.length - 1 - j] == b[b.length - 1 - j]) j++
        // Only a change that starts or ends inside a Latin word takes the rest of the word.
        if ((i < a.length && word(a[i])) || (i < b.length && word(b[i]))) { while (i > 0 && word(a[i - 1])) i-- }
        if ((a.length - j - 1 >= 0 && word(a[a.length - j - 1])) || (b.length - j - 1 >= 0 && word(b[b.length - j - 1]))) {
            while (j > 0 && word(a[a.length - j])) j--
        }
        // Two characters at least, taken from the Chinese side: "FFT制押" → "FFT质押" is "制押" → "质押".
        while (a.length - j - i < 2 || b.length - j - i < 2) {
            if (j > 0 && !word(a[a.length - j])) j-- else if (i > 0 && !word(a[i - 1])) i-- else break
        }
        return a.substring(i, maxOf(i, a.length - j)) to b.substring(i, maxOf(i, b.length - j))
    }

    /// A fix as the UI names it (听成 X → Y, 已改回 X): the changed words, or the whole fix when
    /// it only adds or drops words ("in" → "in now", whose changed part alone would be "" → "now").
    fun label(f: LineFix): Pair<String, String> {
        val c = core(f.from, f.to)
        return if (c.first.isEmpty() || c.second.isEmpty()) f.from to f.to else c
    }

    /// `known`: the user confirmed this heard form for this word (the word list). `rejected`: they
    /// said no to it in this meeting.
    fun decide(e: Edit, known: (String, String) -> Boolean, rejected: (String, String) -> Boolean): Verdict {
        val (cf, ct) = core(e.from, e.to)
        if (cf.isEmpty() || ct.isEmpty() || cf.lowercase() == ct.lowercase() || rejected(e.from, e.to) || rejected(cf, ct)) return Verdict.Drop
        if (known(e.from, e.to) || known(cf, ct)) return Verdict.Apply
        if (e.confidence < APPLY_AT) return Verdict.Drop
        val latinFrom = cf.any { it.code < 128 && it.isLetter() }; val latinTo = ct.any { it.code < 128 && it.isLetter() }
        if (!latinFrom && !latinTo && han(cf) && han(ct) && soundsAlike(cf, ct)) return Verdict.Apply
        if (latinFrom && latinTo && cf.all { it.code < 128 } && ct.all { it.code < 128 } && e.confidence >= SPELLING_AT &&
            distance(cf.lowercase(), ct.lowercase()) <= 2) return Verdict.Apply
        // A new name (Chinese heard as a Latin name, or a respelled one): sound can't check it. A
        // name has a capital or a digit; "X平台 → X platform" is a translation, and one 对 to it
        // taught the word list 平台 → platform, which then rewrote every 平台 in the meeting.
        if (latinTo && e.confidence >= ASK_AT && nameShaped(ct)) return Verdict.Ask
        return Verdict.Drop
    }

    /// Latin text that could be a name: a capital or a digit in it (Morpho, GPT4o), not "platform".
    fun nameShaped(s: String): Boolean = s.any { it.code < 128 && (it.isUpperCase() || it.isDigit()) }

    /// A Chinese word "fixed" into a plain English one (平台 → platform): a translation, not a
    /// misheard name.
    fun translation(heard: String, word: String): Boolean =
        han(heard) && word.any { it.code < 128 && it.isLetter() } && word.all { it.code < 128 } && !nameShaped(word)

    fun pinyin(s: String): List<String> = s.map { pinyinOf(it).trim().lowercase() }

    private val initials = listOf("zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q",
                                  "x", "r", "z", "c", "s", "y", "w")

    private fun split(syllable: String): Pair<String, String> {
        for (i in initials) if (syllable.startsWith(i)) return i to syllable.substring(i.length)
        return "" to syllable
    }

    /// Same number of syllables, and on average three quarters alike: a syllable counts whole when
    /// equal, half when its initial or its final matches (质/追, 销/照). 苍蝇/方向 is a quarter.
    fun soundsAlike(a: String, b: String): Boolean {
        val x = pinyin(a); val y = pinyin(b)
        if (x.size != y.size || x.isEmpty() || x.any { it.isEmpty() } || y.any { it.isEmpty() }) return false
        var score = 0.0
        for ((p, q) in x.zip(y)) {
            if (p == q) { score += 1; continue }
            val (i1, f1) = split(p); val (i2, f2) = split(q)
            if (i1 == i2 || f1 == f2 || f1.replace("ng", "n") == f2.replace("ng", "n")) score += 0.5
        }
        return score / x.size >= 0.75
    }

    fun han(s: String): Boolean = s.isNotEmpty() && s.codePoints().allMatch { Character.isIdeographic(it) }

    fun distance(a: String, b: String): Int {
        val row = IntArray(b.length + 1) { it }
        for ((i, ca) in a.withIndex()) {
            var prev = row[0]
            row[0] = i + 1
            for ((j, cb) in b.withIndex()) {
                val cur = row[j + 1]
                row[j + 1] = minOf(row[j + 1] + 1, row[j] + 1, prev + if (ca == cb) 0 else 1)
                prev = cur
            }
        }
        return row[b.length]
    }

    /// The service's reply to a sentence sent with fixes asked for:
    /// {"translation": "…", "fixes": [{"from", "to", "confidence"}]}. Null when it isn't that shape.
    /// Fixes whose words aren't in the subtitle are dropped: the service sometimes quotes them rephrased.
    fun parse(reply: String, subtitle: String): Pair<String, List<Edit>>? {
        // Asked for JSON in the prompt only: take the outermost {…}, fenced or not.
        val open = reply.indexOf('{'); val close = reply.lastIndexOf('}')
        if (open < 0 || close <= open) return null
        val o = Json.parseObject(reply.substring(open, close + 1)) ?: return null
        val translation = o["translation"].str() ?: return null
        val edits = mutableListOf<Edit>()
        for (f in o["fixes"].arr()) {
            val m = f.obj() ?: continue
            val from = m["from"].str() ?: continue; val to = m["to"].str() ?: continue
            if (from.isEmpty() || from == to || !subtitle.contains(from)) continue
            edits.add(Edit(from, to, (m["confidence"] as? Number)?.toDouble() ?: 0.0))
        }
        return translation.trim() to edits
    }

    /// What a line's fixes become after the service answered for it again (a joined line): the
    /// user's decisions stay (said no, said yes, wrote it), and of the rest only what is proposed
    /// again. So a pass that no longer proposes a fix takes it back.
    fun merge(old: List<LineFix>, new: List<LineFix>): List<LineFix> {
        val kept = old.filter { it.off == true || it.user == true }
        val fresh = new.filter { n ->
            val c = core(n.from, n.to).first
            kept.none { it.from == n.from || core(it.from, it.to).first == c }
        }
        return kept + fresh
    }

    data class UserEdit(val fix: LineFix, val heard: String, val swap: Boolean)

    /// 改这句…: the user rewrote the line as shown. What changed, as a fix on top of the others: the
    /// changed span grown to whole tokens (a Latin word, or one CJK character), and further, a token
    /// at a time, until it holds a letter and is the only such span in the line. An added word
    /// ("lock that in." → "lock that in now.") is then "in" → "in now" on this line, never "." on
    /// every line. `swap` is whether words were replaced (not only added or dropped): only a swap
    /// may go to the rest of the meeting and teach the word list. `heard` is the words in `src`
    /// when they are there, else the heard words of the fix the user corrected again.
    fun userEdit(shown: String, edited: String, src: String, fixes: List<LineFix>): UserEdit? {
        val new = edited.trim()
        if (new.isEmpty() || new == shown) return null
        // Code points, as the Mac's Characters: a span never splits a surrogate pair.
        val a = shown.codePoints().toArray(); val b = new.codePoints().toArray()
        fun str(x: IntArray, from: Int, to: Int) = String(x, from, to - from)
        var p = 0
        while (p < minOf(a.size, b.size) && a[p] == b[p]) p++
        var q = 0
        while (q < minOf(a.size, b.size) - p && a[a.size - 1 - q] == b[b.size - 1 - q]) q++
        val swap = a.size - p - q > 0 && b.size - p - q > 0
        // Tokens of the shown line: a run of ASCII letters and digits, else one character.
        fun latin(c: Int) = c < 128 && Character.isLetterOrDigit(c)
        val tokens = mutableListOf<IntRange>()   // start until end (exclusive)
        var k = 0
        while (k < a.size) {
            var e = k + 1
            if (latin(a[k])) while (e < a.size && latin(a[e])) e++
            tokens.add(k until e)
            k = e
        }
        var start = p; var end = a.size - q
        tokens.firstOrNull { start in it }?.let { start = it.first }
        if (end > start) tokens.firstOrNull { end - 1 in it }?.let { end = it.last + 1 }
        fun span() = str(a, start, end)
        fun count(x: String): Int {
            if (x.isEmpty()) return 0
            var n = 0; var at = shown.indexOf(x)
            while (at >= 0) { n++; at = shown.indexOf(x, at + x.length) }
            return n
        }
        fun replacement() = str(b, start, b.size - (a.size - end))
        // A dropped word ("in now." → "in.") grows too, so neither side of the fix is empty.
        while (span().codePoints().noneMatch { Character.isLetterOrDigit(it) } || count(span()) != 1 || replacement().isEmpty()) {
            val before = tokens.lastOrNull { it.last + 1 <= start }
            val after = tokens.firstOrNull { it.first >= end }
            if (before != null) start = before.first else if (after != null) end = after.last + 1 else break
        }
        val from = span()
        val to = replacement()
        if (from.isEmpty() || from == to) return null
        var heard = from
        if (!src.contains(from)) fixes.firstOrNull { it.applied && from.contains(it.to) }?.let { heard = core(it.from, it.to).first }
        return UserEdit(LineFix(from, to, user = true), heard, swap)
    }

    /// The line as shown: each applied fix replaces its words where they still are. `marks` are
    /// the replaced words (start, end in UTF-16 units), for the dotted underline.
    class Applied(val text: String, val marks: List<IntRange>)

    /// Where `s` stands as words of its own in `text` (its start, or null): a Latin edge of it never
    /// runs on into a Latin word around it. `core` pads a fix to two characters, so the word list
    /// learned "S平 → X平", which matched inside "iOS平台" and made it "iOX平台".
    fun word(s: String, text: String): Int? {
        if (s.isEmpty()) return null
        var from = 0
        while (from < text.length) {
            val at = text.indexOf(s, from)
            if (at < 0) return null
            val end = at + s.length
            val before = at > 0 && word(text[at - 1])
            val after = end < text.length && word(text[end])
            if (!(word(s.first()) && before) && !(word(s.last()) && after)) return at
            from = at + 1
        }
        return null
    }

    fun apply(fixes: List<LineFix>, src: String): Applied {
        var text = src
        val spans = mutableListOf<Pair<String, Int>>()   // replacement and its offset, kept valid as text changes
        // The user's own last: written against the line as it was shown, other fixes in.
        val ordered = fixes.filter { it.user != true } + fixes.filter { it.user == true }
        for (f in ordered) {
            if (!f.applied || f.from.isEmpty()) continue
            val start = word(f.from, text) ?: text.indexOf(f.from)
            if (start < 0) continue
            val delta = f.to.length - f.from.length
            for (k in spans.indices) if (spans[k].second > start) spans[k] = spans[k].first to spans[k].second + delta
            text = text.substring(0, start) + f.to + text.substring(start + f.from.length)
            spans.add(f.to to start)
        }
        val marks = spans.filter { (w, o) -> o + w.length <= text.length && w.isNotEmpty() }
            .map { (w, o) -> o until o + w.length }.sortedBy { it.first }
        return Applied(text, marks)
    }
}
