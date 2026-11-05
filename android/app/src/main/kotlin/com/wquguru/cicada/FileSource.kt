package com.wquguru.cicada

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import cicada.AudioSource
import cicada.Log
import cicada.Segmenter

/// 导入录音或视频: a file's sound, decoded by the phone's own codecs (anything Android plays: m4a,
/// mp3, wav, mp4, mov…), mixed to mono and resampled to 16 kHz, handed on as it decodes. Paced at
/// `speed` × real time: faster than a meeting, slow enough that Ming keeps up (each segment takes
/// ~2 s whatever its length, so several are in flight). Streams, so an hour never sits in memory.
class FileSource(private val context: Context, private val uri: Uri, private val speed: Double = 2.5) : AudioSource {
    override var onSamples: ((ShortArray) -> Unit)? = null
    override var onEnded: ((String?) -> Unit)? = null
    @Volatile private var stopped = false
    /// Seconds handed on so far, and the file's length (0 until known).
    @Volatile var done = 0.0; private set
    @Volatile var total = 0.0; private set

    override fun start() {
        stopped = false
        Thread({
            val reason = try { decode(); null } catch (e: Exception) {
                Log.d("import: decode failed ${e.javaClass.simpleName}: ${e.message}"); "unreadable"
            }
            if (!stopped && reason == null) onSamples?.invoke(ShortArray(Segmenter.RATE)) // the last sentence's pause
            onEnded?.invoke(reason)
        }, "FileSource").apply { isDaemon = true }.start()
    }

    override fun stop() { stopped = true }

    private fun decode() {
        val ex = MediaExtractor()
        ex.setDataSource(context, uri, null)
        val track = (0 until ex.trackCount).firstOrNull { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
            ?: throw IllegalArgumentException("no audio track")
        ex.selectTrack(track)
        val format = ex.getTrackFormat(track)
        if (format.containsKey(MediaFormat.KEY_DURATION)) total = format.getLong(MediaFormat.KEY_DURATION) / 1e6
        val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(format, null, null, 0)
        codec.start()
        var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var pos = 0.0 // the resampler's place in the input, in input samples
        var carry = 0.0f; var hasCarry = false
        val started = System.nanoTime()
        var handed = 0L
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        try {
            while (!stopped) {
                if (!inputDone) {
                    val i = codec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        val n = ex.readSampleData(codec.getInputBuffer(i)!!, 0)
                        if (n < 0) { codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone = true }
                        else { codec.queueInputBuffer(i, 0, n, ex.sampleTime, 0); ex.advance() }
                    }
                }
                val o = codec.dequeueOutputBuffer(info, 10_000)
                if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    rate = codec.outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = codec.outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    continue
                }
                if (o < 0) continue
                val buf = codec.getOutputBuffer(o)!!.order(java.nio.ByteOrder.LITTLE_ENDIAN)
                buf.position(info.offset); buf.limit(info.offset + info.size)
                val shorts = buf.asShortBuffer()
                val frames = shorts.remaining() / channels
                // Mono, then linear resampling to 16 kHz.
                val mono = FloatArray(frames)
                for (f in 0 until frames) { var sum = 0f; for (c in 0 until channels) sum += shorts.get(f * channels + c); mono[f] = sum / channels }
                codec.releaseOutputBuffer(o, false)
                val step = rate.toDouble() / Segmenter.RATE
                val out = ArrayList<Short>(((frames / step) + 2).toInt())
                // `pos` runs from -1 (the previous buffer's last sample, `carry`) to frames-1.
                while (pos < frames - 1 || (pos < frames && frames == 1)) {
                    val i0 = Math.floor(pos).toInt()
                    val a = if (i0 < 0) (if (hasCarry) carry else mono[0]) else mono[i0]
                    val b = mono[minOf(frames - 1, i0 + 1)]
                    val v = a + (b - a) * (pos - i0).toFloat()
                    out.add(v.toInt().coerceIn(-32768, 32767).toShort())
                    pos += step
                }
                pos -= frames
                if (frames > 0) { carry = mono[frames - 1]; hasCarry = true }
                if (out.isNotEmpty()) {
                    // In 100 ms pieces, like a capture callback, paced at `speed`.
                    val all = out.toShortArray()
                    var k = 0
                    val chunk = Segmenter.RATE / 10
                    while (k < all.size && !stopped) {
                        val piece = all.copyOfRange(k, minOf(all.size, k + chunk))
                        onSamples?.invoke(piece)
                        handed += piece.size; k += piece.size
                        done = handed.toDouble() / Segmenter.RATE
                        val due = started + (done / speed * 1e9).toLong()
                        val wait = (due - System.nanoTime()) / 1_000_000
                        if (wait > 0) Thread.sleep(wait)
                    }
                }
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            }
        } finally {
            try { codec.stop() } catch (_: Exception) {}
            codec.release(); ex.release()
        }
        if (total <= 0) total = done
        Log.d("import: decoded ${done.toInt()} s")
    }

    companion object {
        /// The file's name as the picker or the sharing app gives it ("访谈录像.mp4").
        fun name(context: Context, uri: Uri): String {
            try {
                context.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst()) c.getString(0)?.takeIf { it.isNotBlank() }?.let { return it }
                }
            } catch (_: Exception) {}
            return uri.lastPathSegment?.substringAfterLast('/') ?: "audio"
        }
    }
}
