package cicada

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.File
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/// Where listening gets its sound: 16 kHz mono Int16, pushed from any thread. On Android the
/// playback capture or the microphone; in tests, the CLI and the sample meeting, a file.
interface AudioSource {
    /// Set before start(); called on the source's own thread.
    var onSamples: ((ShortArray) -> Unit)?
    /// Called once when the source can't go on: null when a file finished, else why.
    var onEnded: ((String?) -> Unit)?
    fun start()
    fun stop()
}

/// Plays 16 kHz samples into listening, in real time or as fast as it can (`speed` 0).
class PcmAudioSource(private val load: () -> ShortArray, private val speed: Double = 1.0) : AudioSource {
    override var onSamples: ((ShortArray) -> Unit)? = null
    override var onEnded: ((String?) -> Unit)? = null
    @Volatile private var stopped = false

    constructor(file: File, speed: Double = 1.0) : this({ Wav.read(file.inputStream()) }, speed)

    override fun start() {
        stopped = false
        Thread({
            val pcm = try { load() } catch (e: Exception) {
                Log.d("file source: unreadable ${e.javaClass.simpleName}"); onEnded?.invoke("unreadable"); return@Thread
            }
            val chunk = Segmenter.RATE / 10 // 100 ms, like a capture callback
            val started = System.nanoTime()
            var i = 0
            while (i < pcm.size && !stopped) {
                onSamples?.invoke(pcm.copyOfRange(i, minOf(pcm.size, i + chunk)))
                if (speed > 0) {
                    val due = started + ((i + chunk).toDouble() / Segmenter.RATE / speed * 1e9).toLong()
                    val wait = (due - System.nanoTime()) / 1_000_000
                    if (wait > 0) Thread.sleep(wait)
                }
                i += chunk
            }
            // A second of silence so the last sentence's pause is heard.
            onSamples?.invoke(ShortArray(Segmenter.RATE))
            onEnded?.invoke(null)
        }, "PcmAudioSource").apply { isDaemon = true }.start()
    }

    override fun stop() { stopped = true }
}

/// One stretch of speech as sent to Ming: the bytes and their media type.
class Clip(val bytes: ByteArray, val type: String) {
    companion object { fun wav(pcm: ShortArray) = Clip(Wav.bytes(pcm), "audio/wav") }
}

object Wav {
    fun bytes(pcm: ShortArray, rate: Int = Segmenter.RATE): ByteArray {
        val b = ByteBuffer.allocate(44 + pcm.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray()).putInt(36 + pcm.size * 2).put("WAVEfmt ".toByteArray()).putInt(16)
        b.putShort(1).putShort(1).putInt(rate).putInt(rate * 2).putShort(2).putShort(16)
        b.put("data".toByteArray()).putInt(pcm.size * 2)
        for (s in pcm) b.putShort(s)
        return b.array()
    }

    /// A PCM16 WAV of any rate and channel count, as 16 kHz mono.
    fun read(input: InputStream): ShortArray {
        val all = input.use { it.readBytes() }
        val b = ByteBuffer.wrap(all).order(ByteOrder.LITTLE_ENDIAN)
        fun tag(): String { val a = ByteArray(4); b.get(a); return String(a, Charsets.US_ASCII) }
        if (tag() != "RIFF") throw IllegalArgumentException("not a WAV")
        b.int
        if (tag() != "WAVE") throw IllegalArgumentException("not a WAV")
        var channels = 1; var rate = 16000; var bits = 16
        while (b.remaining() >= 8) {
            val id = tag(); val size = b.int
            when (id) {
                "fmt " -> {
                    val start = b.position()
                    val format = b.short.toInt() and 0xFFFF; channels = b.short.toInt(); rate = b.int
                    b.int; b.short; bits = b.short.toInt()
                    b.position(start + size)
                    if ((format != 1 && format != 0xFFFE) || bits != 16) throw IllegalArgumentException("only 16-bit PCM WAV")
                }
                "data" -> {
                    val frames = minOf(size, b.remaining()) / 2 / channels
                    val mono = DoubleArray(frames)
                    for (f in 0 until frames) {
                        var sum = 0.0
                        repeat(channels) { sum += b.short }
                        mono[f] = sum / channels
                    }
                    return resample(mono, rate)
                }
                else -> b.position(minOf(b.limit(), b.position() + size + (size and 1)))
            }
        }
        throw IllegalArgumentException("no data chunk")
    }

    /// Box average then pick: plenty for speech going to a recognizer.
    fun resample(mono: DoubleArray, rate: Int): ShortArray {
        fun clamp(x: Double) = x.coerceIn(Short.MIN_VALUE.toDouble(), Short.MAX_VALUE.toDouble()).toInt().toShort()
        if (rate == Segmenter.RATE) return ShortArray(mono.size) { clamp(mono[it]) }
        val window = maxOf(1, rate / Segmenter.RATE)
        val count = (mono.size.toLong() * Segmenter.RATE / rate).toInt()
        return ShortArray(count) { i ->
            val start = (i.toLong() * rate / Segmenter.RATE).toInt()
            val stop = minOf(mono.size, start + window)
            var sum = 0.0
            for (j in start until stop) sum += mono[j]
            clamp(sum / maxOf(1, stop - start))
        }
    }

    fun rms(buf: ShortArray): Double {
        if (buf.isEmpty()) return 0.0
        var sum = 0.0
        for (s in buf) sum += s.toDouble() * s
        return Math.sqrt(sum / buf.size) / 32768
    }
}
