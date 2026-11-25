package com.wquguru.cicada

import android.content.Context
import cicada.Log
import cicada.Voiceprinter
import java.io.File

/// 说话人识别's voiceprints on the phone: the Mac's model (WeSpeaker ResNet34-LM, VoxCeleb, CC BY
/// 4.0) run by linux/native/voiceprint.c, built with the NDK into libcicada-voice.so (src/main/jni).
/// The weights are linux/models/voiceprint.bin, an asset copied out once (the C reads a file).
/// Should the library not load, `create` gives null and listening carries on unlabelled.
class NativeVoiceprints private constructor(private val context: Context) : Voiceprinter {
    private var model = 0L
    private var tried = false

    override fun embed(samples: ShortArray): FloatArray? {
        val m = synchronized(this) {
            if (!tried) { tried = true; model = load() }
            model
        }
        if (m == 0L) return null
        val out = FloatArray(DIMS)
        // One at a time: each already uses up to four cores.
        return synchronized(this) { if (nativeEmbed(m, samples, samples.size, out) == 0) out else null }
    }

    private fun load(): Long {
        val t = System.currentTimeMillis()
        return try {
            val file = File(context.noBackupFilesDir, "voiceprint.bin")
            val size = context.assets.openFd(ASSET).use { it.length }
            if (file.length() != size) {
                val tmp = File(file.path + ".tmp")
                context.assets.open(ASSET).use { input -> tmp.outputStream().use { input.copyTo(it) } }
                if (!tmp.renameTo(file)) { tmp.delete(); return 0 }
            }
            nativeLoad(file.path).also { Log.d("speakers: voiceprint model ${if (it != 0L) "loaded" else "failed to load"} in ${System.currentTimeMillis() - t} ms") }
        } catch (e: Exception) {
            Log.d("speakers: voiceprint model failed ${e.javaClass.simpleName}")
            0
        }
    }

    private external fun nativeLoad(path: String): Long
    private external fun nativeEmbed(model: Long, samples: ShortArray, n: Int, out: FloatArray): Int

    companion object {
        const val DIMS = 256
        private const val ASSET = "voiceprint.bin"

        fun create(context: Context): NativeVoiceprints? = try {
            System.loadLibrary("cicada-voice")
            NativeVoiceprints(context.applicationContext)
        } catch (e: Throwable) {
            Log.d("speakers: no voiceprint library (${e.javaClass.simpleName})")
            null
        }
    }
}
