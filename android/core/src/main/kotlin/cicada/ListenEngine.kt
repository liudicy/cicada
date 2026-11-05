package cicada

import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/// Listening end to end: audio → segments → Ming (language, original, translation in one call) →
/// lines in the record, plus live notes. UI-free; the app shows the record and listens to
/// `onChange` (called on worker threads: post to the main thread).
///
/// Ming takes ~2.2 s whatever the segment's length, so segments overlap in flight: request starts
/// still go through LingClient's gate, and lines are delivered in segment order.
class ListenEngine(
    private val ling: LingClient,
    private val translator: Translator,
    private val store: SessionStore,
    private val notes: NotesEngine,
    private val settings: AppSettings,
) {
    private val gate = Any()
    private val pool = Executors.newCachedThreadPool { r -> Thread(r, "Listen").apply { isDaemon = true } }
    private var source: AudioSource? = null
    private var audio: LinkedBlockingQueue<ShortArray>? = null
    private var worker: Thread? = null
    private val done = HashMap<Int, Heard?>()
    private val segments = HashMap<Int, Segment>()
    private val inFlight = mutableListOf<Future<*>>()
    private var nextToDeliver = 1
    private var lineCount = 0
    private var last: TranscriptLine? = null
    private var lastEnd = 0.0
    private var hint: String? = null
    private var candidate: String? = null
    private var candidateVotes = 0
    private val listeners = mutableListOf<() -> Unit>()

    @Volatile var listening = false; private set
    @Volatile var sessionId: String? = null; private set
    /// What this meeting is heard from ("playback", "mic", "file").
    @Volatile var sourceKind: String? = null; private set
    /// The meeting's language so far (null until Ming has heard something).
    val spoken: String? get() = synchronized(gate) { hint }
    /// Segments sent and not yet back: the UI shows "…" while this is above zero.
    val pending: Int get() = synchronized(gate) { segments.size }
    /// The last error worth showing ("Ling key 无效", "连不上 Ling"), cleared by the next good reply.
    @Volatile var problem: String? = null; private set
    @Volatile var level = 0.0; private set
    /// Seconds of audio heard this meeting (the capture is alive while this grows).
    @Volatile var heardSeconds = 0.0; private set
    /// The loudest recent level: 0 for a while means the source is silent (e.g. an app that blocks capture).
    @Volatile var peak = 0.0; private set

    /// Compresses a segment before upload (the app sets AAC: WAV is ~10x larger, ~146 MB an hour
    /// of speech on mobile data). Null or a throw falls back to WAV, which Ming always takes.
    @Volatile var encoder: (ShortArray) -> Clip? = { null }

    // The notes' language is read from 设置 when they're written, from launch on: notes generated
    // for an old meeting before anything was listened to used to fall back to Simplified Chinese.
    init {
        translator.glossary = { notes.glossary() }
        notes.language = { Languages.englishName(settings.notesCode) }
    }

    fun onChange(listener: () -> Unit) { synchronized(listeners) { listeners.add(listener) } }
    private fun changed() { synchronized(listeners) { listeners.toList() }.forEach { it() } }

    val target: String get() = settings.targetCode

    private val END = ShortArray(0)
    // Hold and release go through the audio queue, so buffers recorded before the press stay the
    // other side's and those recorded before the release are still mine.
    private val HOLD = ShortArray(0)
    private val RELEASE = ShortArray(0)

    // MARK: 我说 (面对面 only): hold, say something, release → Ming → spoken in their language.

    /// Words were recognised, theirs or mine (a line arrived or grew): what MeetingEndWatch counts.
    var onWords: (() -> Unit)? = null

    /// Speaks my words to the person in front of me: `text` is always a translation (see `speakable`).
    var onSaid: ((text: String, lang: String) -> Unit)? = null
    /// The button is down.
    @Volatile var holding = false; private set
    /// My words are at Ming.
    @Volatile var saying = false; private set
    /// Set while the phone speaks: the mic would hear the translation as the other side, so the
    /// segmenter gets silence instead.
    @Volatile var muted = false
    /// Why the last press said nothing ("没听清，再说一次"); cleared by the next press.
    @Volatile var sayProblem: String? = null; private set
    private val mine = ArrayList<ShortArray>()
    private var holdStart = 0.0
    private var saidCount = 0

    val canSay: Boolean get() = listening && sourceKind == "mic"

    /// Who I'm talking to speaks the meeting's language; before they have said anything (or when
    /// it is mine), English, or Chinese for an English speaker (the Mac always falls back to English).
    val theirLanguage: String get() {
        val me = target
        val heard = spoken
        if (heard != null && !Languages.same(heard, me)) return heard
        return if (me.startsWith("en")) "zh-CN" else "en"
    }

    fun hold() {
        if (!canSay || holding) return
        holding = true
        sayProblem = null
        audio?.offer(HOLD)
        changed()
    }

    /// The app couldn't speak a translation ("手机没有这个语言的语音").
    fun sayFailed(why: String) { sayProblem = why; changed() }

    /// Debug: audio as if the source had just delivered it (the emulator's microphone is silent).
    fun inject(pcm: ShortArray) {
        var i = 0
        while (i < pcm.size) { audio?.offer(pcm.copyOfRange(i, minOf(pcm.size, i + 1600))); i += 1600 }
    }

    fun release() {
        if (!holding) return
        holding = false
        audio?.offer(RELEASE)
        changed()
    }

    /// Sees every buffer as heard, on the audio thread (保存会议录音, an import's progress): it
    /// must only hand the buffer on.
    @Volatile var tap: ((ShortArray) -> Unit)? = null

    fun start(from: AudioSource, kind: String) {
        if (listening) return
        val session = store.begin()
        sessionId = session.id
        sourceKind = kind
        synchronized(gate) {
            done.clear(); segments.clear(); inFlight.clear()
            nextToDeliver = 1; lineCount = 0; last = null; lastEnd = 0.0
            hint = null; candidate = null; candidateVotes = 0; problem = null
        }
        holding = false; saying = false; muted = false; sayProblem = null; saidCount = 0
        heardSeconds = 0.0; peak = 0.0
        notes.begin(session.id)
        val segmenter = Segmenter()
        segmenter.onSegment = ::send
        val queue = LinkedBlockingQueue<ShortArray>()
        audio = queue
        // One worker owns the segmenter: audio callbacks only queue buffers.
        worker = Thread({
            var mineOpen = false
            while (true) {
                val buf = queue.take()
                if (buf === END) break
                if (buf === HOLD) { mineOpen = true; synchronized(mine) { mine.clear() }; holdStart = heardSeconds; continue }
                if (buf === RELEASE) { if (mineOpen) { mineOpen = false; finishSaying() }; continue }
                if (mineOpen) synchronized(mine) { mine.add(buf) }
                // Silence, not nothing, so the segmenter's clock keeps step with the meeting's.
                segmenter.feed(if (mineOpen || muted) ShortArray(buf.size) else buf)
                level = Wav.rms(buf)
                peak = maxOf(peak * 0.995, level)
                heardSeconds += buf.size / Segmenter.RATE.toDouble()
            }
            segmenter.flush()
        }, "ListenWorker").apply { isDaemon = true; start() }
        source = from
        from.onSamples = { tap?.invoke(it); queue.offer(it) }
        // Listening before the source starts: a source that fails at once calls onEnded → stop(),
        // which must see this meeting as running to end it.
        listening = true
        from.start()
        Log.d("listen: started ${session.id} source=$kind target=$target")
        changed()
    }

    /// Stops listening, waits (briefly) for segments still at Ming, ends the record and starts the
    /// final notes. Blocks until the record is saved: call off the main thread.
    fun stop(endedAt: java.time.Instant? = null) {
        if (!listening) return
        // This meeting's id now: a new one may start while this waits for Ming below.
        val id = sessionId ?: return
        listening = false
        source?.let { it.onSamples = null; it.stop() }
        audio?.offer(END)
        worker?.join(5000)
        val waiting = synchronized(gate) { inFlight.toList() }
        val deadline = System.currentTimeMillis() + 15_000
        for (f in waiting) {
            try { f.get(maxOf(1, deadline - System.currentTimeMillis()), TimeUnit.MILLISECONDS) } catch (_: Exception) {}
        }
        store.end(id, endedAt)
        Log.d("listen: stopped $id, $lineCount lines")
        changed()
        pool.execute { notes.finish() }
    }

    private fun finishSaying() {
        val pcm = synchronized(mine) {
            val all = ShortArray(mine.sumOf { it.size }); var at = 0
            for (b in mine) { b.copyInto(all, at); at += b.size }
            mine.clear(); all
        }
        if (pcm.size < Segmenter.RATE / 2 || Wav.rms(pcm) < 0.003) {
            sayProblem = if (pcm.size < Segmenter.RATE / 2) Strings.L("按住说完再松开") else Strings.L("没听到声音，靠近手机再说")
            changed(); return
        }
        saying = true
        changed()
        val t = Math.round(holdStart * 1000) / 1000.0
        pool.execute { say(pcm, t) }
    }

    private fun say(pcm: ShortArray, t: Double) {
        val id = sessionId ?: run { saying = false; return }
        val their = theirLanguage
        val me = target
        try {
            val heard = translator.hear(encode(pcm), their, me, pcm.size / Segmenter.RATE.toDouble())
            if (heard == null) { sayProblem = Strings.L("没听清，再说一次"); return }
            var dst = heard.translation
            if (dst == null && !Languages.same(heard.lang, their)) dst = translator.translate(heard.original, heard.lang, their, Translator.Kind.Sentence)
            val sameLanguage = Languages.same(heard.lang, their)
            val probe = TranscriptLine(speaker = "me", src = heard.original, dst = dst, srcLang = heard.lang, dstLang = their)
            val text = speakable(probe)
            Log.d("listen: said ${heard.lang} -> $their, ${if (text != null) "speaking" else "not spoken"}")
            // As on the Mac: a sentence that didn't translate is neither sent nor recorded. One
            // already in their language was heard as it is, so it is kept.
            if (text == null && !sameLanguage) { sayProblem = Strings.L("翻译失败，这句话未发送"); return }
            val n = synchronized(gate) { ++saidCount }
            val line = TranscriptLine(id = "m$n", t = t, speaker = "me", src = heard.original, dst = dst,
                                      srcLang = heard.lang, dstLang = their)
            // The other side's next words start their own line, never joined onto mine.
            synchronized(gate) { last = null }
            store.append(id, line.copy())
            onWords?.invoke()
            if (text != null) onSaid?.invoke(text, their) else sayProblem = Strings.L("这句已经是对方的语言")
        } catch (e: LingException) {
            sayProblem = when (e.kind) {
                LingException.Kind.NoKey, LingException.Kind.InvalidKey -> Strings.L("Ling key 无效")
                LingException.Kind.Network, LingException.Kind.Timeout -> Strings.L("连不上 Ling，检查网络")
                else -> Strings.L("没听清，再说一次")
            }
            Log.d("listen: saying failed ${e.message}")
        } catch (e: Exception) {
            sayProblem = Strings.L("没听清，再说一次")
            Log.d("listen: saying failed ${e.javaClass.simpleName}")
        } finally {
            saying = false
            changed()
        }
    }

    private fun encode(pcm: ShortArray): Clip {
        val clip = try { encoder(pcm) } catch (e: Exception) { Log.d("listen: encode failed ${e.message}"); null }
        if (clip == null || clip.bytes.isEmpty()) return Clip.wav(pcm)
        return clip
    }

    private fun send(seg: Segment) {
        val lang = synchronized(gate) { segments[seg.index] = seg; hint }
        // Timing only (never text): where the segment sits in the audio, to measure delay.
        Log.d("listen: segment ${seg.index} sent at ${"%.2f".format(seg.start)}+${"%.2f".format(seg.seconds)}")
        changed()
        val future = pool.submit {
            var heard: Heard? = null
            val started = System.currentTimeMillis()
            try {
                val clip = encode(seg.samples)
                // Into what the meeting's language translates to; a segment that turns out to be
                // in my own language under "follow system" is translated again (record).
                val asked = settings.targetFor(lang)
                heard = translator.hear(clip, asked, lang, seg.seconds)?.let { h ->
                    if (settings.targetFor(h.lang) == asked) h else h.copy(translation = null)
                }
                problem = null
            } catch (e: LingException) {
                problem = when (e.kind) {
                    LingException.Kind.NoKey -> Strings.L("需要 Ling key 才能听")
                    LingException.Kind.InvalidKey -> Strings.L("Ling key 无效")
                    LingException.Kind.RateLimited -> Strings.L("Ling 太忙，稍后再试")
                    LingException.Kind.Network, LingException.Kind.Timeout -> Strings.L("连不上 Ling，检查网络")
                    else -> null
                }
                Log.d("listen: segment ${seg.index} failed ${e.message}")
            } catch (e: Exception) {
                Log.d("listen: segment ${seg.index} failed ${e.javaClass.simpleName}")
            }
            Log.d("listen: segment ${seg.index} ${"%.1f".format(seg.seconds)}s -> ${heard?.lang ?: "nothing"} in ${System.currentTimeMillis() - started} ms")
            synchronized(gate) { done[seg.index] = heard }
            deliver()
        }
        synchronized(gate) { inFlight.add(future); inFlight.removeAll { it.isDone } }
    }

    /// Hands finished segments on in order: one slow reply holds back those after it.
    private fun deliver() {
        val ready = mutableListOf<Pair<Segment, Heard?>>()
        synchronized(gate) {
            while (done.containsKey(nextToDeliver)) {
                val heard = done.remove(nextToDeliver)
                ready.add(segments.remove(nextToDeliver)!! to heard)
                nextToDeliver++
            }
        }
        for ((seg, heard) in ready) if (heard != null) record(seg, heard)
        if (ready.isNotEmpty()) changed()
    }

    private fun record(seg: Segment, heard: Heard) {
        val id = sessionId ?: return
        val target = settings.targetFor(heard.lang)
        // The meeting's language moves only after two segments agree, so one misheard stretch
        // doesn't flip the hint (the Mac waits for confidence the same way).
        synchronized(gate) {
            val h = hint
            if (h == null) hint = heard.lang
            else if (heard.lang != h) {
                if (candidate == heard.lang) candidateVotes++ else { candidate = heard.lang; candidateVotes = 1 }
                if (candidateVotes >= 2) { hint = candidate; candidate = null; candidateVotes = 0 }
            } else { candidate = null; candidateVotes = 0 }
        }

        val line: TranscriptLine
        var joined = false
        synchronized(gate) {
            val prev = last
            if (prev != null && continues(prev, seg.start - lastEnd, heard)) {
                prev.src = join(prev.src, heard.original, heard.lang)
                prev.dst = if (prev.dst == null || heard.translation == null) null else join(prev.dst!!, heard.translation, target)
                line = prev
                joined = true
            } else {
                line = TranscriptLine(id = "h${++lineCount}-${seg.index}", t = seg.start, speaker = "them",
                                      src = heard.original, dst = heard.translation, srcLang = heard.lang, dstLang = target)
                last = line
            }
            lastEnd = seg.start + seg.seconds
        }
        val copy = synchronized(gate) { line.copy() }
        if (joined) store.replace(id, copy) else store.append(id, copy)
        onWords?.invoke()

        // A joined sentence is translated again as a whole; a line Ming didn't translate gets text translation.
        if ((joined || line.dst == null) && line.srcLang != target) {
            val src = line.src
            pool.execute {
                val dst = translator.translate(src, line.srcLang, target, Translator.Kind.Sentence)
                val updated = synchronized(gate) {
                    if (dst == null || line.src != src) return@execute
                    line.dst = dst
                    line.copy()
                }
                store.replace(id, updated)
                changed()
            }
        }
    }

    companion object {
        /// What may be spoken into the room for a line: my words' translation, never my own words.
        fun speakable(line: TranscriptLine): String? {
            val dst = line.dst?.trim() ?: return null
            if (line.speaker != "me" || dst.isEmpty() || Languages.same(line.srcLang, line.dstLang) || dst == line.src.trim()) return null
            return dst
        }

        /// A segment continues the last line when the cut came mid-sentence: no sentence end on the
        /// last line, a short gap, the same language, and the joined line not too long to read.
        fun continues(last: TranscriptLine, gap: Double, next: Heard): Boolean {
            if (gap > 0.8 || last.srcLang != next.lang) return false
            val text = last.src.trimEnd()
            if (text.isEmpty() || ".!?。！？…".contains(text.last())) return false
            val cjk = Languages.isCjkLanguage(next.lang)
            val size = if (cjk) text.length + next.original.length else "$text ${next.original}".split(' ').count { it.isNotEmpty() }
            return size <= if (cjk) 80 else 45
        }

        fun join(a: String, b: String, lang: String): String {
            val cjk = lang.startsWith("zh") || lang.startsWith("ja")
            return if (cjk) a.trimEnd() + b.trimStart() else a.trimEnd() + " " + b.trimStart()
        }
    }
}
