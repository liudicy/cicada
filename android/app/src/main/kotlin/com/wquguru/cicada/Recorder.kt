package com.wquguru.cicada

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import cicada.Log
import cicada.Segmenter
import java.io.File
import java.util.concurrent.Executors

/// 保存会议录音: what was heard, as the Mac keeps it (system.m4a beside session.json, AAC mono).
/// Written to a .partial file and renamed when the meeting ends, so a record never points at a
/// half-written file. The audio thread only hands buffers over; encoding has its own thread.
class Recorder(private val target: File) {
    private val partial = File(target.path + ".partial")
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "Recorder").apply { isDaemon = true } }
    private var codec: MediaCodec? = null
    private var muxer: MediaMuxer? = null
    private var track = -1
    private var samples = 0L
    private var failed = false

    init {
        worker.execute {
            try {
                partial.parentFile?.mkdirs()
                val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, Segmenter.RATE, 1).apply {
                    setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    setInteger(MediaFormat.KEY_BIT_RATE, 32_000)
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16_384)
                }
                codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).apply { configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE); start() }
                muxer = MediaMuxer(partial.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            } catch (e: Exception) { fail(e) }
        }
    }

    fun write(pcm: ShortArray) { if (!failed) worker.execute { feed(pcm, false) } }

    /// Ends the file; `done(true)` once system.m4a is in place. Called off the main thread is fine.
    fun finish(done: (Boolean) -> Unit) {
        worker.execute {
            if (!failed) feed(ShortArray(0), true)
            val ok = !failed && try {
                if (track >= 0) muxer?.stop()
                muxer?.release(); codec?.stop(); codec?.release()
                track >= 0 && partial.renameTo(target)
            } catch (e: Exception) { fail(e); false }
            if (!ok) partial.delete()
            Log.d("recorder: ${if (ok) "saved ${target.length() / 1024} KB, ${samples / Segmenter.RATE} s" else "nothing saved"}")
            done(ok)
        }
        worker.shutdown()
    }

    private fun feed(pcm: ShortArray, end: Boolean) {
        val c = codec ?: return
        try {
            var off = 0
            var queuedEnd = false
            var tries = 0
            do {
                val i = c.dequeueInputBuffer(10_000)
                if (i < 0 && ++tries > 300) throw IllegalStateException("encoder stalled")
                if (i >= 0) {
                    val buf = c.getInputBuffer(i)!!
                    buf.clear()
                    val n = minOf(pcm.size - off, buf.remaining() / 2)
                    for (k in 0 until n) buf.putShort(pcm[off + k])
                    val us = samples * 1_000_000 / Segmenter.RATE
                    off += n; samples += n
                    val last = end && off >= pcm.size
                    c.queueInputBuffer(i, 0, n * 2, us, if (last) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0)
                    if (last) queuedEnd = true
                }
                drain(c, false)
            } while (off < pcm.size || (end && !queuedEnd))
            if (end) drain(c, true)
        } catch (e: Exception) { fail(e) }
    }

    private fun drain(c: MediaCodec, untilEnd: Boolean) {
        val info = MediaCodec.BufferInfo()
        var waits = 0
        while (waits < 300) {
            if (untilEnd) waits++
            val o = c.dequeueOutputBuffer(info, if (untilEnd) 10_000 else 0)
            when {
                o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> { track = muxer!!.addTrack(c.outputFormat); muxer!!.start() }
                o >= 0 -> {
                    val out = c.getOutputBuffer(o)!!
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0 && track >= 0) muxer!!.writeSampleData(track, out, info)
                    c.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
                o == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!untilEnd) return
            }
        }
    }

    private fun fail(e: Exception) {
        if (!failed) Log.d("recorder: failed ${e.javaClass.simpleName}: ${e.message}")
        failed = true
    }
}
