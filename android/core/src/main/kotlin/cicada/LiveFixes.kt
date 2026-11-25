package cicada

/// 改正听错的词 (the Mac's LiveFixes.swift), between the translation and the records: which fixes a
/// line takes, which wait for the user (待确认), and what the user's answers and edits teach the
/// word list. Who wins: the user's own decisions, then the word list, then a later pass, then the
/// first guess. UI-free and thread-safe: proposals arrive on listening's threads, taps on the main
/// one. The screens show `pending`, `asking` and `toast` and pass taps back.
class LiveFixes(val store: SessionStore, val vocabulary: Vocabulary, private val settings: AppSettings) {
    /// The last thing the user did, said back with 撤销 for a few seconds (`TOAST_MS`).
    class Toast(val text: String, val at: Long = System.currentTimeMillis())
    @Volatile var toast: Toast? = null; private set

    /// Fixes said no to in this meeting ("from→to"), and how often each heard form was turned down
    /// overall this run: twice and it leaves the word list.
    private val refused = HashSet<String>()
    private val refusals = HashMap<String, Int>()
    /// 稍后再看 on the card: still waiting, but asked again only after the meeting.
    private val deferred = HashSet<String>()
    /// What 撤销 puts back: the lines' fixes and the word list as they were.
    private class Step(val session: String, val lines: Map<String, List<LineFix>>, val words: List<Vocabulary.Term>,
                       val refused: Set<String>, val deferred: Set<String>)
    private val undoStack = ArrayDeque<Step>()
    private val listeners = mutableListOf<() -> Unit>()

    fun onChange(listener: () -> Unit) { synchronized(listeners) { listeners.add(listener) } }
    private fun changed() { synchronized(listeners) { listeners.toList() }.forEach { it() } }

    @Synchronized fun meetingStarted() { refused.clear(); deferred.clear(); undoStack.clear() }

    private fun pair(a: String, b: String) = a + "\u001F" + b
    private fun key(f: LineFix) = Correction.core(f.from, f.to).let { pair(it.first, it.second) }

    // MARK: The service's proposals

    /// What a finished sentence's request carries (the Mac's FixContext); null while fixing is off.
    class Context(val topic: String?, val words: List<String>, val recent: List<String>,
                  val following: List<String> = emptyList(), val summary: String? = null)

    fun context(text: String): Context? {
        if (!settings.fixMisheard) return null
        val words = vocabulary.promptLines()
        val (id, line) = store.lineHeard(text) ?: return Context(null, words, emptyList())
        val s = store.get(id) ?: return Context(null, words, emptyList())
        val lines = store.lines(id)
        val i = lines.indexOfFirst { it.id == line.id }
        return Context(
            topic = s.notes?.title ?: if (s.renamed == true) s.title else null,
            words = words,
            recent = if (i < 0) emptyList() else lines.subList(maxOf(0, i - 3), i).map { it.shown },
            following = if (i < 0) emptyList() else lines.subList(i + 1, minOf(lines.size, i + 4)).map { it.shown },
            summary = s.notes?.summary?.takeIf { it.isNotEmpty() },
        )
    }

    /// The service's proposals for a line heard as `text` (none at all is an answer too: a second
    /// pass takes back what isn't proposed again).
    @Synchronized fun received(text: String, edits: List<Correction.Edit>) {
        if (!settings.fixMisheard) return
        val (id, line) = store.lineHeard(text) ?: return
        val fresh = mutableListOf<LineFix>()
        for (e in edits) {
            val verdict = Correction.decide(e, known = { a, b -> vocabulary.knows(a, b) }, rejected = { a, b -> pair(a, b) in refused })
            Log.d("fix $verdict c=${"%.2f".format(e.confidence)} line=${line.id}")
            when {
                verdict == Correction.Verdict.Apply -> {
                    fresh.add(LineFix(e.from, e.to))
                    // A listed word counts as used whichever way the fix was found (a sound-alike too).
                    vocabulary.used(Correction.core(e.from, e.to).second)
                }
                verdict == Correction.Verdict.Ask && settings.askNames -> fresh.add(LineFix(e.from, e.to, ask = true))
            }
        }
        val before = line.fixes ?: emptyList()
        val fixes = known(line.src, Correction.merge(before, fresh))
        val dropped = before.count { it.applied && it.user != true && it !in fixes }
        if (dropped > 0) Log.d("fix recheck took back $dropped line=${line.id}")
        set(fixes, line.id, id)
    }

    /// The word list's confirmed heard forms, fixed without asking anyone: also with no AI service.
    /// Two characters at least, so a single 压 never turns into 押 everywhere.
    @Synchronized fun applyKnown(lineId: String, id: String) {
        if (!settings.fixMisheard) return
        val l = store.line(id, lineId) ?: return
        set(known(l.src, l.fixes ?: emptyList()), lineId, id)
    }

    private fun known(src: String, fixes: List<LineFix>): List<LineFix> {
        val out = fixes.toMutableList()
        for (t in vocabulary.terms) {
            for (h in t.heard) {
                // A heard form two words claim (两个都留) is never fixed silently. A translation a yes taught
                // before that was refused (平台 → platform) isn't either; one the user typed is.
                if (t.source != "user" && Correction.translation(h, t.word)) continue
                if (h.length < 2 || Correction.word(h, src) == null || pair(h, t.word) in refused || vocabulary.owners(h, t.word).isNotEmpty()) continue
                if (out.any { it.from == h || (it.applied && it.from.contains(h)) || (it.off == true && it.from == h) }) continue
                out.add(LineFix(h, t.word))
            }
        }
        return out
    }

    private fun set(fixes: List<LineFix>, lineId: String, id: String) {
        val l = store.line(id, lineId) ?: return
        if (fixes == (l.fixes ?: emptyList<LineFix>())) return
        store.setFixes(id, lineId, fixes)
        changed()
    }

    // MARK: 待确认

    class Waiting(val line: TranscriptLine, val fix: LineFix)

    /// 待确认 in a meeting: each (from → to) once, oldest first.
    fun pending(id: String): List<Waiting> {
        val seen = HashSet<String>()
        val out = mutableListOf<Waiting>()
        for (l in store.lines(id)) for (f in l.fixes ?: emptyList()) if (f.ask == true && seen.add(key(f))) out.add(Waiting(l, f))
        return out
    }

    /// What the live card asks now: not what was put off (稍后再看), and only the first few, so a
    /// burst of names doesn't keep the card up all meeting. `of`: how many in this run.
    class Asking(val line: TranscriptLine, val fix: LineFix, val of: Int)

    @Synchronized fun asking(id: String): Asking? {
        val open = pending(id).filter { key(it.fix) !in deferred }
        val first = open.firstOrNull() ?: return null
        return Asking(first.line, first.fix, minOf(open.size, ASK_AT_ONCE))
    }

    /// × on the card: 稍后再看, asked again after the meeting (the record's banner).
    @Synchronized fun later(fix: LineFix, id: String) {
        remember(id, emptyList())
        deferred.add(key(fix))
        say(Strings.L("已收进人名和术语，稍后再看"))
    }

    /// 对 / 不对 on a waiting fix: every line in the meeting waiting on the same change follows,
    /// and a yes goes into the word list so the next meeting fixes it without asking.
    @Synchronized fun answer(fix: LineFix, yes: Boolean, id: String) {
        val c = Correction.core(fix.from, fix.to)
        val lines = store.lines(id)
        val touched = lines.filter { l -> (l.fixes ?: emptyList()).any { it.ask == true && Correction.core(it.from, it.to) == c } }
        val others = if (yes) lines.filter { l -> l.src.contains(c.first) && touched.none { it.id == l.id } } else emptyList()
        remember(id, (touched + others).map { it.id })
        for (l in touched) {
            val fixes = (l.fixes ?: emptyList()).map { f ->
                if (f.ask == true && Correction.core(f.from, f.to) == c) f.copy(ask = null, user = if (yes) true else f.user, off = if (yes) f.off else true) else f
            }
            set(fixes, l.id, id)
        }
        if (yes) {
            vocabulary.confirm(c.first, c.second)
            // The rest of the meeting heard the same way follows now, not with the next line.
            for (l in others) applyKnown(l.id, id)
        } else {
            refused.add(pair(c.first, c.second))
        }
        Log.d("fix answered ${if (yes) "yes" else "no"}")
        say(if (yes) Strings.LF("已改 %@ → %@，记进词表", c.first, c.second) else Strings.LF("这场不再问 %@", c.first))
    }

    /// 改回: this line goes back to what was heard, and the meeting stops making this change.
    @Synchronized fun revert(fix: LineFix, lineId: String, id: String) {
        val l = store.line(id, lineId) ?: return
        val fixes = l.fixes ?: return
        // The one still on: an earlier, already undone copy of the same change may sit before it.
        val k = fixes.indexOfFirst { it.from == fix.from && it.to == fix.to && it.applied }
            .takeIf { it >= 0 } ?: fixes.indexOfFirst { it.from == fix.from && it.to == fix.to }
        if (k < 0) return
        remember(id, listOf(lineId))
        set(fixes.mapIndexed { i, f -> if (i == k) f.copy(off = true, ask = null, user = null) else f }, lineId, id)
        val c = Correction.core(fix.from, fix.to)
        refused.add(pair(c.first, c.second)); refused.add(pair(fix.from, fix.to))
        val n = (refusals[pair(c.first, c.second)] ?: 0) + 1
        refusals[pair(c.first, c.second)] = n
        if (n >= 2) vocabulary.forget(c.first, c.second)
        Log.d("fix reverted line=$lineId")
        say(Strings.LF("已改回 %@，这场不再改", Correction.label(fix).first))
    }

    // MARK: 改这句…

    class Same(val heard: String, val count: Int, val swap: Boolean)

    /// How many lines of the meeting the same edit would change ("整场听成 木娜 的 2 处都改").
    /// An edit that only adds or drops words stays on its line (count 1, nothing to learn).
    fun sameHeard(lineId: String, id: String, edited: String): Same? {
        val lines = store.lines(id)
        val l = lines.firstOrNull { it.id == lineId } ?: return null
        val e = Correction.userEdit(l.shown, edited, l.src, l.fixes ?: emptyList()) ?: return null
        val n = if (e.swap) lines.count { it.shown.contains(e.fix.from) } else 1
        return Same(e.heard, maxOf(1, n), e.swap)
    }

    /// The user rewrote a line (改这句…): what changed becomes their own fix, on this line or on
    /// every line showing the same words, and with `keep` the heard form joins the word list.
    @Synchronized fun edit(lineId: String, id: String, edited: String, everywhere: Boolean, keep: Boolean): Int {
        val lines = store.lines(id)
        val l = lines.firstOrNull { it.id == lineId } ?: return 0
        val e = Correction.userEdit(l.shown, edited, l.src, l.fixes ?: emptyList()) ?: return 0
        val (fix, heard) = e
        val everywhere = everywhere && e.swap
        val targets = if (everywhere) lines.filter { it.shown.contains(fix.from) } else listOf(l)
        remember(id, targets.map { it.id })
        for (t in targets) {
            // A guess still waiting on the same words is answered by the edit: not that.
            // The same change made again replaces any earlier copy (say, one undone with 改回).
            val fixes = (t.fixes ?: emptyList()).filter { !(it.from == fix.from && it.to == fix.to) }.map { f ->
                if (f.ask == true && (f.from.contains(heard) || heard.contains(f.from))) f.copy(ask = null, off = true) else f
            }
            set(fixes + fix, t.id, id)
        }
        val word = Correction.core(fix.from, fix.to).second.trim()
        // Only a change made everywhere teaches the word list (a one-off must not), and only a
        // word for a word (`Vocabulary.learnable`).
        val learned = keep && everywhere && Vocabulary.learnable(heard, word) != null
        if (learned) vocabulary.confirm(heard, word, "user")
        Log.d("fix edited lines=${targets.size} learned=$learned")
        // A swap reads as the words swapped; an added or dropped word as the span it changed
        // ("in → in now", not "in → now").
        val (a, b) = if (e.swap) heard to word else fix.from to fix.to
        say(if (learned) Strings.LF("已改 %lld 处：%@ → %@，记进词表", targets.size, a, b) else Strings.LF("已改 %lld 处：%@ → %@", targets.size, a, b))
        return targets.size
    }

    // MARK: 撤销

    private fun remember(id: String, lines: List<String>) {
        val all = store.lines(id)
        val before = lines.associateWith { lid -> all.firstOrNull { it.id == lid }?.fixes?.map { it.copy() } ?: emptyList() }
        undoStack.addLast(Step(id, before, vocabulary.terms, refused.toSet(), deferred.toSet()))
        if (undoStack.size > 20) undoStack.removeFirst()
    }

    val canUndo: Boolean @Synchronized get() = undoStack.isNotEmpty()

    @Synchronized fun undo() {
        val step = undoStack.removeLastOrNull() ?: return
        for ((lid, fixes) in step.lines) store.setFixes(step.session, lid, fixes)
        vocabulary.restore(step.words)
        refused.clear(); refused.addAll(step.refused)
        deferred.clear(); deferred.addAll(step.deferred)
        toast = null
        Log.d("fix undone")
        changed()
    }

    /// The toast while it is up.
    fun toastNow(now: Long = System.currentTimeMillis()): Toast? = toast?.takeIf { now - it.at < TOAST_MS }

    private fun say(text: String) {
        toast = Toast(text)
        changed()
    }

    companion object {
        /// The card asks about at most this many names in a row; the rest wait for after the meeting.
        const val ASK_AT_ONCE = 3
        const val TOAST_MS = 6000L
    }
}
