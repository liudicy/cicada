package com.wquguru.cicada

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.os.Process
import cicada.AudioSource
import cicada.Log
import cicada.Segmenter

/// Reads an AudioRecord at 16 kHz mono on its own thread and hands each buffer on: the audio
/// thread only copies, ListenEngine's worker does the rest. Android resamples for us.
abstract class RecordSource : AudioSource {
    override var onSamples: ((ShortArray) -> Unit)? = null
    override var onEnded: ((String?) -> Unit)? = null
    @Volatile private var running = false
    private var record: AudioRecord? = null
    /// Android silenced this recording (a call, or another app holding the microphone), or let it go.
    var onSilenced: ((Boolean) -> Unit)? = null
    protected open fun watch(r: AudioRecord) {}
    protected open fun unwatch() {}

    protected abstract fun make(format: AudioFormat, bufferBytes: Int): AudioRecord
    protected open fun released() {}

    override fun start() {
        val format = AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(Segmenter.RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO).build()
        val min = AudioRecord.getMinBufferSize(Segmenter.RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val r = try { make(format, maxOf(min, Segmenter.RATE)) } catch (e: Exception) {
            Log.d("capture: ${javaClass.simpleName} failed ${e.javaClass.simpleName}: ${e.message}")
            onEnded?.invoke("unavailable"); return
        }
        if (r.state != AudioRecord.STATE_INITIALIZED) { r.release(); onEnded?.invoke("unavailable"); return }
        record = r
        running = true
        r.startRecording()
        watch(r)
        Log.d("capture: ${javaClass.simpleName} started")
        Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            val buf = ShortArray(Segmenter.RATE / 10) // 100 ms
            while (running) {
                val n = r.read(buf, 0, buf.size)
                if (n > 0) onSamples?.invoke(buf.copyOf(n))
                else if (n < 0) { Log.d("capture: read error $n"); if (running) onEnded?.invoke("read error"); break }
            }
            unwatch()
            try { r.stop() } catch (_: Exception) {}
            r.release()
            released()
        }, "Capture").start()
    }

    override fun stop() { running = false }
}

/// What other apps play (Android 10+): media, games and unknown usages, never Cicada itself.
/// Call and meeting apps are not captured (their usage is voice communication, and apps can opt
/// out), which is why there is a microphone mode too.
class PlaybackSource(private val projection: MediaProjection, private val ownUid: Int) : RecordSource() {
    @SuppressLint("MissingPermission")
    override fun make(format: AudioFormat, bufferBytes: Int): AudioRecord {
        val config = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .excludeUid(ownUid)
            .build()
        return AudioRecord.Builder().setAudioFormat(format).setBufferSizeInBytes(bufferBytes).setAudioPlaybackCaptureConfig(config).build()
    }

    override fun released() { projection.stop() }
}

/// 面对面: the phone's microphone, tuned for speech.
class MicSource(private val context: android.content.Context) : RecordSource() {
    private var callback: android.media.AudioManager.AudioRecordingCallback? = null
    private val audio get() = context.getSystemService(android.media.AudioManager::class.java)

    // During a phone call Android keeps the recording running but feeds it silence: say so
    // instead of looking like nobody is talking.
    override fun watch(r: AudioRecord) {
        val session = r.audioSessionId
        val cb = object : android.media.AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(configs: MutableList<android.media.AudioRecordingConfiguration>) {
                val mine = configs.firstOrNull { it.clientAudioSessionId == session } ?: return
                Log.d("capture: mic silenced=${mine.isClientSilenced}")
                onSilenced?.invoke(mine.isClientSilenced)
            }
        }
        callback = cb
        audio.registerAudioRecordingCallback(cb, null)
    }

    override fun unwatch() { callback?.let { audio.unregisterAudioRecordingCallback(it) }; callback = null }

    @SuppressLint("MissingPermission")
    override fun make(format: AudioFormat, bufferBytes: Int): AudioRecord =
        AudioRecord.Builder().setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION).setAudioFormat(format).setBufferSizeInBytes(bufferBytes).build()
}
