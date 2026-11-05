package cicada

/// A stretch of speech to send to Ming: where it starts (seconds since listening began) and its
/// 16 kHz mono samples.
class Segment(val index: Int, val start: Double, val samples: ShortArray) {
    val seconds get() = samples.size / Segmenter.RATE.toDouble()
}

/// Cuts the audio into stretches of speech by loudness alone: a pause of 0.6 s ends one, and one
/// that runs to 8 s is cut at its quietest moment in the last 2 s, so a word is split as rarely as
/// possible (Ming has no word timings to put it back together). Not thread-safe: fed from the
/// listening worker only. Same numbers as the Windows Segmenter. (A meeting's first stretch was once
/// cut at 4 s to show a line sooner: Ming then finished the cut sentence by itself, and the rest
/// came back as a second, duplicate line.)
class Segmenter {
    companion object {
        const val RATE = 16000
        private const val FRAME = 480 // 30 ms
        @Volatile var threshold = 0.01 // the Mac AudioRouter's gate (about -40 dBFS)
        @Volatile var pause = 0.6
        @Volatile var maxLength = 8.0
        @Volatile var minSpeech = 0.25
        private const val PRE_ROLL = 0.15
        private const val TAIL = 0.15
        private const val CUT_WINDOW = 2.0
    }

    private val pending = ShortList()            // samples not yet a whole frame
    private val current = ShortList()            // the open segment
    private val levels = ArrayList<Double>()     // per frame of `current`
    private val before = ArrayDeque<ShortArray>() // recent quiet frames, for the pre-roll
    private var consumed = 0L                    // samples seen, for timestamps
    private var currentStart = 0.0
    private var quietFrames = 0
    private var loudFrames = 0
    private var index = 0

    var onSegment: ((Segment) -> Unit)? = null

    fun feed(samples: ShortArray) {
        pending.addAll(samples, 0, samples.size)
        val whole = pending.size / FRAME * FRAME
        var i = 0
        while (i < whole) { step(pending.slice(i, i + FRAME)); i += FRAME }
        pending.removeFirst(whole)
    }

    /// Ends the open segment (listening stopped).
    fun flush() {
        if (current.size > 0) close(current.size - quietFrames * FRAME + (TAIL * RATE).toInt())
    }

    private fun step(frame: ShortArray) {
        val level = Wav.rms(frame)
        val loud = level >= threshold
        val now = consumed / RATE.toDouble()
        consumed += frame.size

        if (current.size == 0) {
            if (!loud) {
                before.addLast(frame)
                while (before.size > PRE_ROLL * RATE / FRAME) before.removeFirst()
                return
            }
            currentStart = now - before.size * FRAME / RATE.toDouble()
            for (f in before) { current.addAll(f, 0, f.size); levels.add(0.0) }
            before.clear()
            quietFrames = 0; loudFrames = 0
        }

        current.addAll(frame, 0, frame.size)
        levels.add(level)
        if (loud) { quietFrames = 0; loudFrames++ } else quietFrames++

        if (quietFrames * FRAME >= pause * RATE) {
            close(current.size - quietFrames * FRAME + (TAIL * RATE).toInt())
        } else if (current.size >= maxLength * RATE) {
            // The quietest frame in the last 2 s; the rest starts the next segment.
            val from = maxOf(1, levels.size - (CUT_WINDOW * RATE / FRAME).toInt())
            var cut = from
            for (i in from until levels.size) if (levels[i] < levels[cut]) cut = i
            close(cut * FRAME)
        }
    }

    /// Emits `current[0 until end]` and keeps what follows as the start of the next segment.
    private fun close(endAt: Int) {
        val end = endAt.coerceIn(0, current.size)
        val samples = current.slice(0, end)
        val rest = current.slice(end, current.size)
        val restLevels = ArrayList(levels.subList(minOf(levels.size, end / FRAME), levels.size))
        val start = currentStart
        val speech = loudFrames * FRAME >= minSpeech * RATE
        current.clear(); levels.clear()
        quietFrames = 0; loudFrames = 0
        if (speech) onSegment?.invoke(Segment(++index, Math.round(start * 1000) / 1000.0, samples))

        // A forced cut carries on with the remainder; after a pause the remainder is silence.
        if (restLevels.any { it >= threshold }) {
            currentStart = start + end / RATE.toDouble()
            current.addAll(rest, 0, rest.size)
            levels.addAll(restLevels)
            var trailing = 0
            for (i in levels.indices.reversed()) { if (levels[i] >= threshold) break; trailing++ }
            quietFrames = trailing
            loudFrames = levels.count { it >= threshold }
        }
    }
}

/// A growable ShortArray (no boxing on the audio path).
internal class ShortList {
    private var a = ShortArray(RATE_HINT)
    var size = 0; private set

    fun addAll(src: ShortArray, from: Int, to: Int) {
        val n = to - from
        if (size + n > a.size) a = a.copyOf(maxOf(a.size * 2, size + n))
        System.arraycopy(src, from, a, size, n)
        size += n
    }

    fun slice(from: Int, to: Int): ShortArray = a.copyOfRange(from, to)

    fun removeFirst(n: Int) {
        System.arraycopy(a, n, a, 0, size - n)
        size -= n
    }

    fun clear() { size = 0 }

    private companion object { const val RATE_HINT = 16000 }
}
