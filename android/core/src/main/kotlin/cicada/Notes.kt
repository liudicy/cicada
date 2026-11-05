package cicada

import java.time.Instant
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/// Keeps the live meeting's notes up to date: every ~45 s with new speech, one Ling call sends the
/// current notes plus the new lines and gets the whole notes back as JSON; a final pass rewrites
/// them over the whole transcript when the meeting ends. A failed or odd reply never replaces good
/// notes. The prompt and parsing are the Mac's (Notes.swift, via the Windows port), so all write
/// the same notes.
class NotesEngine(private val ling: LingClient, private val store: SessionStore) {
    enum class State { Idle, Updating, NoKey, InvalidKey, RateLimited, Failed }

    private val gate = Any()
    private val timer = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "Notes").apply { isDaemon = true } }
    private val work = Executors.newSingleThreadExecutor { r -> Thread(r, "NotesWork").apply { isDaemon = true } }
    private var tick: ScheduledFuture<*>? = null
    private var sessionId: String? = null
    private var inFlight = false
    private var pendingFinal: String? = null
    private var lastAttempt = 0L
    private val listeners = mutableListOf<() -> Unit>()

    @Volatile var notes = MeetingNotes(); private set
    @Volatile var status = State.Idle; private set
    /// The session the notes belong to (stays set after the meeting ends).
    @Volatile var shownId: String? = null; private set
    /// The language notes are written in (English name), from 纪要语言.
    @Volatile var language: () -> String = { "Simplified Chinese" }

    fun onChange(listener: () -> Unit) { synchronized(listeners) { listeners.add(listener) } }
    private fun changed() { synchronized(listeners) { listeners.toList() }.forEach { it() } }

    /// Names for the translation glossary: "江充 (note; misheard as 江松, 江冲)".
    fun glossary(): List<String> = notes.terms.take(30).map {
        if (it.heard.isEmpty()) "${it.name} (${it.note})" else "${it.name} (${it.note}; misheard as ${it.heard.joinToString(", ")})"
    }

    fun begin(id: String) {
        synchronized(gate) {
            sessionId = id; shownId = id
            notes = store.get(id)?.notes ?: MeetingNotes()
            status = if (ling.hasKey) State.Idle else State.NoKey
            lastAttempt = System.currentTimeMillis()
            tick?.cancel(false)
            tick = timer.scheduleWithFixedDelay({ tick() }, 5, 5, TimeUnit.SECONDS)
        }
        changed()
    }

    /// The meeting ended: one last pass over the whole transcript. Blocks until it's written.
    fun finish() {
        val id = synchronized(gate) {
            tick?.cancel(false); tick = null
            val id = sessionId; sessionId = null; id
        } ?: return
        update(id, final = true)
    }

    fun show(id: String) {
        synchronized(gate) { shownId = id; notes = store.get(id)?.notes ?: MeetingNotes() }
        changed()
    }

    /// The finished meeting whose notes are being written on request (the UI shows it working).
    @Volatile var generating: String? = null; private set

    /// Notes for a finished meeting that has none (runs in the background; repeat taps are one).
    fun generate(id: String) {
        if (generating == id) return
        generating = id
        changed()
        work.execute {
            try { update(id, final = true) } finally { generating = null; changed() }
        }
    }

    private fun tick() {
        val id = synchronized(gate) {
            // A key added or replaced since: clear the old complaint (an invalid key stays invalid
            // until it's changed, which resets the client's keyState).
            if ((status == State.NoKey || status == State.InvalidKey) && ling.usable) { status = State.Idle; changed() }
            val id = sessionId ?: return
            if (inFlight) return
            val s = store.get(id) ?: return
            if (s.lines.size <= notes.covered) return
            val since = (System.currentTimeMillis() - lastAttempt) / 1000.0
            // First notes as soon as there is something to say, then every 45 s.
            val due = if (notes.isEmpty) s.lines.size >= 3 || since > 20 else since >= INTERVAL
            if (!due) return
            id
        }
        work.execute { update(id, final = false) }
    }

    private fun update(id: String, final: Boolean) {
        val session: Session
        val base: MeetingNotes
        synchronized(gate) {
            if (inFlight) { if (final) pendingFinal = id; return }
            session = store.get(id) ?: return
            if (session.lines.isEmpty()) return
            if (!ling.hasKey) { status = State.NoKey; changed(); return }
            inFlight = true
            lastAttempt = System.currentTimeMillis()
            status = State.Updating
            base = if (final) MeetingNotes() else if (id == shownId) notes else session.notes ?: MeetingNotes()
        }
        changed()
        try {
            val lines = store.lines(id)
            val from = if (final) 0 else minOf(base.covered, lines.size)
            val lang = language()
            val prompt = prompt(base, lines, from, lang, final)
            var next: MeetingNotes? = null
            for (attempt in 1..(if (final) 2 else 1)) {
                val raw = ling.chat(prompt, "Update the notes. Write them in $lang.", Priority.Notes, json = true, maxTokens = 6000, timeout = 90.0)
                val parsed = parse(raw, lines.map { it.t }, lines.firstOrNull()?.t ?: 0.0) ?: break
                if (written(parsed, lang)) { next = parsed; break }
                Log.d("notes: ${if (final) "final" else "live"} reply not in $lang (attempt $attempt), dropped")
            }
            if (next == null) {
                Log.d("notes: no usable reply, kept the previous notes")
                status = State.Failed
                return
            }
            carryTimes(base, next)
            next.title = next.title ?: base.title ?: session.notes?.title
            next.covered = lines.size
            next.updatedAt = Instant.now()
            next.final = final
            synchronized(gate) { if (id == shownId) notes = next }
            store.setNotes(id, next)
            status = State.Idle
            Log.d("notes: ${if (final) "final" else "live"} update ${lines.size - from} new lines -> ${next.topics.size} topics, ${next.terms.size} terms")
        } catch (e: LingException) {
            status = when (e.kind) {
                LingException.Kind.InvalidKey -> State.InvalidKey
                LingException.Kind.RateLimited -> State.RateLimited
                LingException.Kind.NoKey -> State.NoKey
                else -> State.Failed
            }
            Log.d("notes: update failed ${e.message}")
        } catch (e: Exception) {
            status = State.Failed
            Log.d("notes: update failed ${e.javaClass.simpleName}")
        } finally {
            val queued = synchronized(gate) { inFlight = false; pendingFinal.also { pendingFinal = null } }
            changed()
            if (queued != null) update(queued, final = true)
        }
    }

    companion object {
        const val INTERVAL = 45.0

        /// The model echoes points it already had without evidence: keep the times they had, and a
        /// point keeps the time it was first heard.
        fun carryTimes(old: MeetingNotes, next: MeetingNotes) {
            val known = HashMap<String, Double>()
            for (t in old.topics) for (i in t.points.indices) t.pointTime(i)?.let { known.putIfAbsent(t.points[i], it) }
            for (t in next.topics) {
                val times = t.points.mapIndexed { i, p -> min(t.pointTime(i), known[p]) }.toMutableList()
                t.pointTimes = if (times.any { it != null }) times else null
            }
            val items = HashMap<String, Double>()
            for (i in old.conclusions + old.todos) i.t?.let { items.putIfAbsent(i.text, it) }
            for (i in next.conclusions + next.todos) i.t = min(i.t, items[i.text])
        }

        private fun min(a: Double?, b: Double?) = if (a == null) b else if (b == null) a else minOf(a, b)

        fun written(notes: MeetingNotes, language: String) =
            Languages.writtenIn(notes.summary + notes.topics.joinToString("") { it.title }, language)

        // MARK: Prompt (Notes.swift › prompt, word for word)

        fun prompt(notes: MeetingNotes, lines: List<TranscriptLine>, from: Int, language: String, final: Boolean): String {
            fun line(i: Int): String {
                val l = lines[i]
                val who = if (l.speaker == "me") "你" else "对方"
                return "[L${i + 1} ${Languages.clock(l.t)} $who] ${l.src}"
            }
            val current = if (notes.isEmpty) "{}" else compactJson(notes)
            val context = maxOf(0, from - 2)
            var p = "You keep notes for a meeting ${if (final) "that has just ended. Rewrite them from the whole transcript" else "that is still going on. Update them with the new lines"}.\n" +
                "Write the notes in $language. Return JSON only.\n"
            if (!final) p += "Current notes (JSON):\n$current\n\n"
            if (context < from) p += "Already covered (context only):\n" + (context until from).joinToString("\n") { line(it) } + "\n\n"
            p += "${if (final) "Transcript" else "New lines"} (id, mm:ss, speaker 对方=the other side / 你=me / a name or 说话人N=one person on the other side, told apart by voice and possibly wrong / 未识别=someone on the other side not identified, text). Speech recognition makes mistakes, often in names: correct them from context, and write a public figure's name as the news spells it.\n"
            p += (from until lines.size).joinToString("\n") { line(it) }
            if (final && lines.isNotEmpty()) {
                val span = lines.last().t - lines.first().t
                val most = maxOf(1, minOf(8, (span / 180).toInt() + 1))
                p += "\n\nThis meeting ran ${Languages.clock(span)}: use at most $most topic${if (most == 1) "" else "s"}."
            } else if (!final && notes.topics.isNotEmpty() && lines.isNotEmpty() && lines.last().t - notes.topics.last().start < 120) {
                val topic = notes.topics.last()
                p += "\n\nThe current topic \"${topic.title}\" started at ${Languages.clock(topic.start)}, under 2 minutes ago: do not start a new topic in this update; add the new lines to it."
            } else if (!final && notes.topics.isEmpty()) {
                p += "\n\nThese are the first lines: make one topic."
            }
            p += "\n\nReturn the full notes as one JSON object with exactly these keys:\n" +
                "{\"title\": \"the meeting's name: what it is about, a few words\",\n" +
                " \"summary\": \"2-3 sentences on the whole meeting so far\",\n" +
                " \"topics\": [{\"start\": seconds, \"title\": \"short title\", \"summary\": \"one sentence\", \"points\": [{\"text\": \"key point\", \"evidence\": [\"L4\"]}], \"evidence\": [\"L3\"],\n" +
                "             \"fishbone\": null or {\"question\": \"the problem or question\", \"branches\": [{\"label\": \"2-6 words\", \"detail\": \"one short line\", \"t\": seconds, \"evidence\": [\"L5\"]}]}}],\n" +
                " \"conclusions\": [{\"text\": \"...\", \"evidence\": [\"L7\", \"L8\"]}],\n" +
                " \"todos\": [{\"text\": \"...\", \"owner\": \"对方\" or \"你\" or null, \"evidence\": [\"L9\"]}],\n" +
                " \"terms\": [{\"name\": \"correct spelling\", \"note\": \"who or what, a few words\", \"heard\": [\"how it was misrecognised\"]}]}\n" +
                "Rules (be brief: these notes are read at a glance during the meeting):\n" +
                "- title: a name for the whole meeting, like a calendar entry (at most 12 Chinese characters or 6 words; no date, no quotes, not \"会议\" alone). Keep the current title unless the meeting's subject has clearly changed.\n" +
                "- summary: at most 3 short sentences.\n" +
                "- Topics in time order, at most 8 in total. A topic is a stretch of the meeting, usually 3-10 minutes, not a single remark: start a new one only when the subject clearly changes and the current topic started at least 2 minutes before the newest line${if (final) "" else "; add at most one new topic per update"}. Otherwise add to the current one, and merge small neighbouring topics. Keep earlier topics as they are unless new lines correct them. The last topic is the one being discussed now.\n" +
                "- At most 4 points per topic, each one short phrase. Merge rather than repeat.\n" +
                "- At most 5 conclusions and only real to-dos (often none).\n" +
                "- Add a fishbone only to a topic that discusses causes, reasons or factors (3-5 branches); otherwise null.\n" +
                "- Every topic, point, branch, conclusion and to-do needs evidence: the ids of the lines that say it. Never state anything the transcript does not say.\n" +
                "- terms: at most 10 in total, replacing less useful ones rather than adding: first names the transcript misspells (heard), then the people, places and jargon a reader would not know. Leave out what everyone knows (a famous company, index or politician) unless it was misheard. name is the correct spelling in the transcript's language (no translation in brackets); heard lists only the wrong forms the transcript used; note is a few words.\n" +
                "- Write the meeting title and every summary, title, point, branch, conclusion and to-do in $language, even when the transcript is in another language. Only term names keep the transcript's spelling.\n" +
                "- Write about what was said, never about the transcript or recognition quality.\n" +
                "- Use empty arrays when there is nothing. No markdown, no text outside the JSON."
            return p
        }

        /// The current notes as sent back to the model (no bookkeeping fields).
        private fun compactJson(n: MeetingNotes): String {
            val o = linkedMapOf<String, Any?>()
            if (n.title != null) o["title"] = n.title
            o["summary"] = n.summary
            o["topics"] = n.topics.map {
                mapOf("start" to it.start, "title" to it.title, "summary" to it.summary, "points" to it.points, "fishbone" to it.fishbone?.toJson())
            }
            o["conclusions"] = n.conclusions.map { it.text }
            o["todos"] = n.todos.map { it.text }
            o["terms"] = n.terms.map { it.toJson() }
            return Json.write(o, pretty = false)
        }

        // MARK: Parse

        /// Lenient: missing keys become empty, evidence ids are checked against the transcript.
        fun parse(raw: String, times: List<Double>, startedAt: Double): MeetingNotes? {
            val a = raw.indexOf('{'); val b = raw.lastIndexOf('}')
            if (a < 0 || b <= a) return null
            val root = Json.parseObject(raw.substring(a, b + 1)) ?: return null

            fun s(v: Any?) = (v as? String)?.trim() ?: ""
            fun lineNumbers(v: Any?): Set<Int> = v.arr().mapNotNull { id ->
                s(id).dropWhile { !it.isDigit() }.takeWhile { it.isDigit() }.toIntOrNull()?.takeIf { it in 1..times.size }
            }.toSet()
            fun support(v: Any?) = lineNumbers(v).size
            fun time(v: Any?): Double? = lineNumbers(v).minOrNull()?.let { times[it - 1] }
            fun objects(v: Any?) = v.arr().mapNotNull { it.obj() }

            val n = MeetingNotes(summary = s(root["summary"]))
            val title = s(root["title"]).trim('"', '“', '”', '「', '」', '《', '》')
            n.title = title.ifEmpty { null }
            for (t in objects(root["topics"])) {
                val topicTitle = s(t["title"])
                if (topicTitle.isEmpty()) continue
                var fish: Fishbone? = null
                t["fishbone"].obj()?.let { f ->
                    val branches = objects(f["branches"]).map { br ->
                        FishboneBranch(label = s(br["label"]), detail = s(br["detail"]), t = br["t"].num(), support = support(br["evidence"]))
                    }.filter { it.label.isNotEmpty() }.toMutableList()
                    if (branches.size >= 2) fish = Fishbone(s(f["question"]), branches)
                }
                val points = mutableListOf<String>()
                val pointTimes = mutableListOf<Double?>()
                for (p in t["points"].arr()) {
                    val po = p.obj()
                    val text = if (po != null) s(po["text"]) else s(p)
                    if (text.isEmpty()) continue
                    points.add(text)
                    pointTimes.add(po?.let { time(it["evidence"]) })
                }
                n.topics.add(NoteTopic(start = t["start"].num() ?: startedAt, title = topicTitle, summary = s(t["summary"]), points = points,
                                       pointTimes = if (pointTimes.any { it != null }) pointTimes else null, fishbone = fish))
            }
            fun items(key: String) = objects(root[key]).map { i ->
                NoteItem(text = s(i["text"]), owner = s(i["owner"]).ifEmpty { null }, support = support(i["evidence"]), t = time(i["evidence"]))
            }.filter { it.text.isNotEmpty() }.toMutableList()
            n.conclusions = items("conclusions")
            n.todos = items("todos")
            n.terms = objects(root["terms"]).map { t ->
                val name = s(t["name"])
                NoteTerm(name = name, note = s(t["note"]), heard = t["heard"].arr().map { s(it) }.filter { it.isNotEmpty() && it != name }.toMutableList())
            }.filter { it.name.isNotEmpty() }.toMutableList()
            // The model keeps every term it ever had: bound the glossary, keeping the misheard ones.
            if (n.terms.size > 20) n.terms = NoteTerm.ordered(n.terms).take(20).toMutableList()
            return if (n.isEmpty) null else n
        }
    }
}
