package com.wquguru.cicada

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import cicada.Clip
import cicada.Segmenter
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/// A segment as AAC-LC in ADTS frames ("audio/aac"), which Ming hears as well as WAV at ~1/10 the
/// size. ADTS needs no muxer or temp file: each encoded frame gets a 7-byte header. Null when the
/// device has no usable encoder; the caller then sends WAV.
object AacEncoder {
    private const val BITRATE = 24_000
    private const val TIMEOUT_US = 10_000L

    fun encode(pcm: ShortArray, rate: Int = Segmenter.RATE): Clip? {
        val freq = FREQ_INDEX[rate] ?: return null
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, 1).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, BITRATE)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16 * 1024)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            val bytes = ByteBuffer.allocate(pcm.size * 2).order(ByteOrder.LITTLE_ENDIAN)
            for (s in pcm) bytes.putShort(s)
            bytes.flip()
            val out = ByteArrayOutputStream(pcm.size / 4)
            val info = MediaCodec.BufferInfo()
            var fed = 0L
            var inputDone = false
            // Bounded so a stuck codec can't hold a segment forever (~2 s without output).
            var idle = 0
            while (idle < 200) {
                if (!inputDone) {
                    val i = codec.dequeueInputBuffer(1_000)
                    if (i >= 0) {
                        val buf = codec.getInputBuffer(i)!!
                        buf.clear()
                        val n = minOf(buf.remaining(), bytes.remaining())
                        val slice = bytes.slice(); slice.limit(n); buf.put(slice)
                        bytes.position(bytes.position() + n)
                        val timeUs = fed * 1_000_000L / rate
                        fed += n / 2
                        inputDone = !bytes.hasRemaining()
                        codec.queueInputBuffer(i, 0, n, timeUs, if (inputDone) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0)
                    }
                }
                // Drain everything ready without waiting while there is input left to feed:
                // waiting on each frame here made a 7 s segment take a second to encode.
                while (true) {
                    val o = codec.dequeueOutputBuffer(info, if (inputDone) TIMEOUT_US else 0)
                    if (o < 0) { if (inputDone) idle++; break }
                    idle = 0
                    val buf = codec.getOutputBuffer(o)!!
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                        buf.position(info.offset); buf.limit(info.offset + info.size)
                        out.write(adts(info.size, freq))
                        val frame = ByteArray(info.size); buf.get(frame); out.write(frame)
                    }
                    codec.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        return if (out.size() > 0) Clip(out.toByteArray(), "audio/aac") else null
                    }
                }
            }
            return null
        } finally {
            try { codec.stop() } catch (_: Exception) {}
            codec.release()
        }
    }

    private val FREQ_INDEX = mapOf(48000 to 3, 44100 to 4, 32000 to 5, 24000 to 6, 22050 to 7, 16000 to 8, 12000 to 9, 11025 to 10, 8000 to 11)

    /// ADTS header for one AAC-LC mono frame of `size` bytes.
    private fun adts(size: Int, freq: Int): ByteArray {
        val len = size + 7
        val profile = 1 // AAC LC (object type 2) minus one
        val channels = 1
        return byteArrayOf(
            0xFF.toByte(), 0xF1.toByte(),
            ((profile shl 6) or (freq shl 2) or (channels shr 2)).toByte(),
            (((channels and 3) shl 6) or (len shr 11)).toByte(),
            ((len and 0x7FF) shr 3).toByte(),
            (((len and 7) shl 5) or 0x1F).toByte(),
            0xFC.toByte(),
        )
    }
}
