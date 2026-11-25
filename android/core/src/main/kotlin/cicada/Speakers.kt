package cicada

import kotlin.math.sqrt

/// 说话人识别: telling the other side's voices apart (SpeakerID.swift; linux/cicada/core/speakers.py).
/// Each heard line's audio becomes a voiceprint (WeSpeaker ResNet34-LM, VoxCeleb, CC BY 4.0),
/// voiceprints are grouped as they arrive, and a voice is only shown once it has a few lines
/// (SpeakerLabels). The thresholds are the Mac's, tuned on AMI meetings.
///
/// The model runs in linux/native/voiceprint.c, built into the app with the NDK: the app gives a
/// `Voiceprinter`; this plain-JVM side only groups. Without one the feature is unavailable and
/// listening carries on as before.
interface Voiceprinter {
    /// A unit-length voiceprint of 16 kHz mono samples, or null (too short, or it failed).
    fun embed(samples: ShortArray): FloatArray?
}

/// Groups voiceprints as lines arrive, never revising a line already labelled. A line joins the
/// closest voice when similar enough; a long line unlike every voice starts a new one; anything
/// else stays unlabelled (对方). (VoiceClusterer, SpeakerID.swift.)
class VoiceClusterer {
    private val sums = ArrayList<FloatArray>()

    /// The user said two voices are one: later lines like either go to `into`.
    fun merge(from: Int, into: Int) {
        if (from !in sums.indices || into !in sums.indices || from == into) return
        val a = sums[into]; val b = sums[from]
        for (i in a.indices) a[i] += b[i]
        b.fill(0f) // never the closest again
    }

    fun label(v: FloatArray, seconds: Double): Int? {
        var best = -1; var bestSim = -1f
        for ((i, s) in sums.withIndex()) {
            var dot = 0f; var sq = 0f
            for (k in s.indices) { dot += v[k] * s[k]; sq += s[k] * s[k] }
            val sim = dot / maxOf(sqrt(sq), 1.1920929e-07f)
            if (sim > bestSim) { bestSim = sim; best = i }
        }
        if (best >= 0 && bestSim >= JOIN) {
            val s = sums[best]
            for (k in s.indices) s[k] += v[k]
            return best
        }
        if (seconds >= NEW_SECONDS && (sums.isEmpty() || bestSim < START_NEW)) {
            sums.add(v.copyOf())
            return sums.size - 1
        }
        return null
    }

    companion object {
        const val NEW_SECONDS = 2.0
        const val JOIN = 0.5f
        const val START_NEW = 0.5f
    }
}

/// Voiceprints for listening: `embed` runs on the engine's voice thread while Ming hears the same
/// segment; `label` is called in segment order.
open class SpeakerTagger(private val voiceprints: Voiceprinter?) {
    private val gate = Any()
    private var clusterer = VoiceClusterer()

    val available: Boolean get() = voiceprints != null

    /// A new meeting: forget the voices of the last one.
    fun reset() = synchronized(gate) { clusterer = VoiceClusterer() }

    fun merge(from: Int, into: Int) = synchronized(gate) { clusterer.merge(from, into) }

    fun embed(samples: ShortArray): FloatArray? {
        if (samples.size < MIN_SECONDS * Segmenter.RATE) return null
        return voiceprints?.embed(samples)
    }

    open fun label(vector: FloatArray?, seconds: Double): Int? {
        vector ?: return null
        return synchronized(gate) { clusterer.label(vector, seconds) }
    }

    companion object { const val MIN_SECONDS = 0.5 }
}

/// Names from the conversation (SpeakerNameGuess, SpeakerNamer): asks Ling on its own once two
/// voices are on show, again every 20 lines, and once more when the meeting ends. Guesses go
/// straight into the meeting (voiceGuesses); the user corrects them.
class SpeakerNamer(private val ling: LingClient, private val store: SessionStore) {
    private val gate = Any()
    private val busy = HashSet<String>()
    private val asked = HashMap<String, Int>()

    fun guess(id: String, force: Boolean = false) {
        val s = store.get(id) ?: return
        if (!ling.hasKey) return
        val text: String
        val lines: List<TranscriptLine>
        synchronized(gate) {
            lines = store.lines(id)
            if (id in busy || !(force || lines.size >= (asked[id] ?: -1000) + 20)) return
            text = content(lines) ?: return
            val numbers = SpeakerLabels.voiceNumbers(lines)
            if (numbers.keys.all { s.voiceNames?.get(it.toString()) != null }) return // everyone already has the user's name
            busy.add(id)
            asked[id] = lines.size
        }
        Thread({
            try {
                val reply = ling.chat(text, INSTRUCTION, Priority.Notes, json = true, maxTokens = 300)
                val (found, refuted) = read(reply, lines)
                for ((key, g) in s.voiceGuesses ?: emptyMap()) {
                    val v = key.toIntOrNull() ?: continue
                    if (v !in found && !holds(g, v, lines)) refuted[v] = g.name
                }
                store.setVoiceGuesses(id, found, refuted)
                Log.d("speakers: names ${found.size} found, ${refuted.size} without evidence")
            } catch (e: LingException) {
                Log.d("speakers: names, ling failed ${e.message}")
            } catch (e: Exception) {
                Log.d("speakers: names failed ${e.javaClass.simpleName}")
            } finally {
                synchronized(gate) { busy.remove(id) }
            }
        }, "SpeakerNames").apply { isDaemon = true }.start()
    }

    companion object {
        /// Ling's prompt, word for word the Mac's.
        const val INSTRUCTION = "Who are the people labelled 说话人N? Name one only when the transcript makes it clear: they " +
            "introduce themselves on a line labelled with their own 说话人N; someone addresses them by name just " +
            "before or after they speak (\"Thanks, George\" right after 说话人1's answer: 说话人1 is George); " +
            "or others name them as they speak. A name on a 对方 line, or far from any line of 说话人N (an advert, " +
            "a clip, people introducing themselves on another show), is not theirs. Speech recognition writes " +
            "names by ear and often misspells them: for a public figure (an official, an executive, a presenter) " +
            "recognisable from the name and what is said, write the name as the news spells it (\"Jensen Hwang\" " +
            "→ \"Jensen Huang\"); otherwise as written. Leave out anyone " +
            "you are unsure of. Reply as JSON: {\"speakers\": [{\"speaker\": 2, \"name\": \"George\", \"evidence\": \"L12\"}]}, " +
            "the evidence being the line with the name; an empty list if none. Check each name's spelling before replying."

        /// "Okay, Amos, thank you" comes right after Amos's last words.
        const val EVIDENCE_REACH = 2

        /// The transcript as Ling sees it, newest 400 lines, with speaker labels; null when no voices are shown.
        fun content(lines: List<TranscriptLine>): String? {
            val numbers = SpeakerLabels.voiceNumbers(lines)
            if (numbers.isEmpty()) return null
            val sb = StringBuilder("Meeting transcript. Speakers: 你 = the user; 说话人N = one person on the other side, told apart by voice; " +
                "对方 = someone on the other side, not identified.\n")
            for ((i, l) in lines.takeLast(400).withIndex()) {
                val n = if (l.speaker == "them") l.voice?.let { numbers[it] } else null
                val who = if (l.speaker == "me") "你" else if (n != null) "说话人$n" else "对方"
                sb.append("[L${i + 1} ${Languages.clock(l.t)} $who] ${l.shown}\n")
            }
            return sb.toString()
        }

        /// (found: voice → guess, refuted: voice → name). A name given on a line the voice neither
        /// said nor spoke next to is refuted; a name Ling gives two voices goes to the one with more lines.
        fun read(reply: String, all: List<TranscriptLine>): Pair<MutableMap<Int, VoiceGuess>, MutableMap<Int, String>> {
            val found = LinkedHashMap<Int, VoiceGuess>(); val refuted = LinkedHashMap<Int, String>()
            // Without JSON mode (a host that refuses it) the object may come in a fence or a sentence.
            val a = reply.indexOf('{'); val z = reply.lastIndexOf('}')
            val list = (if (a in 0 until z) Json.parseObject(reply.substring(a, z + 1)) else null)?.get("speakers").arr() ?: return found to refuted
            val voiceOf = SpeakerLabels.voiceNumbers(all).entries.associate { (v, n) -> n to v }
            val lines = all.takeLast(400)
            fun count(v: Int) = all.count { it.voice == v }
            for (item in list) {
                val o = item.obj() ?: continue
                val n = o["speaker"]?.toString()?.removeSuffix(".0")?.toIntOrNull() ?: continue
                val v = voiceOf[n] ?: continue
                val name = o["name"].str()?.trim() ?: continue
                if (name.isEmpty() || name.length > 40) continue
                val e = o["evidence"]?.toString() ?: ""
                val i = (e.dropWhile { !it.isDigit() }.takeWhile { it.isDigit() }.toIntOrNull() ?: 0) - 1
                val near = if (i in lines.indices) lines.subList(maxOf(0, i - EVIDENCE_REACH), minOf(lines.size, i + EVIDENCE_REACH + 1)) else emptyList()
                if (near.none { it.speaker == "them" && it.voice == v }) { refuted[v] = name; continue }
                val other = found.entries.firstOrNull { it.value.name == name }?.key
                if (other != null) {
                    if (count(other) >= count(v)) continue
                    found.remove(other)
                }
                val l = lines[i]
                val quote = if (l.shown.length > 60) l.shown.take(60) + "…" else l.shown
                found[v] = VoiceGuess(name, "${Languages.clock(l.t)} “$quote”")
            }
            return found to refuted
        }

        /// Whether a stored guess still stands: its evidence line is found again and the voice speaks there.
        fun holds(g: VoiceGuess, v: Int, lines: List<TranscriptLine>): Boolean {
            if (!g.evidence.contains("“")) return true
            val at = g.evidence.substringBefore("“").trim()
            val quote = g.evidence.substringAfter("“").removeSuffix("”").substringBefore("…")
            for ((i, l) in lines.withIndex()) {
                if (Languages.clock(l.t) == at && l.shown.startsWith(quote))
                    return lines.subList(maxOf(0, i - EVIDENCE_REACH), minOf(lines.size, i + EVIDENCE_REACH + 1))
                        .any { it.speaker == "them" && it.voice == v }
            }
            return true
        }
    }
}
