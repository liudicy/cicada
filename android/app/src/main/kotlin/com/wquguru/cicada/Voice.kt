package com.wquguru.cicada

import android.content.Context
import android.media.AudioAttributes
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import cicada.Log
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/// The system's text-to-speech, for saying my translated words to the person in front of me.
/// Only ever given a translation (ListenEngine.said checks that): never what I said myself.
class Voice(private val context: Context) {
    enum class Result { Spoken, NoVoice, Failed }

    private var tts: TextToSpeech? = null
    private var ready = CountDownLatch(1)
    private var ok = false
    @Volatile var speaking = false; private set

    /// Starts the engine early (it takes ~1 s), so the first sentence isn't late.
    fun warm() { engine() }

    @Synchronized private fun engine(): TextToSpeech? {
        tts?.let { return if (ready.await(3, TimeUnit.SECONDS) && ok) it else null }
        ready = CountDownLatch(1)
        val t = TextToSpeech(context.applicationContext) { status ->
            ok = status == TextToSpeech.SUCCESS
            Log.d("voice: engine ${if (ok) "ready" else "failed $status"}")
            ready.countDown()
        }
        t.setAudioAttributes(AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANT)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
        tts = t
        return if (ready.await(3, TimeUnit.SECONDS) && ok) t else null
    }

    fun has(lang: String): Boolean {
        val t = engine() ?: return false
        val r = t.isLanguageAvailable(Locale.forLanguageTag(lang))
        return r >= TextToSpeech.LANG_AVAILABLE
    }

    /// Speaks `text` in `lang`; `onStart` / `onEnd` come on a TTS thread. Call off the main thread
    /// (waits for the engine the first time).
    fun speak(text: String, lang: String, onStart: () -> Unit, onEnd: () -> Unit): Result {
        val t = engine() ?: return Result.Failed
        val locale = Locale.forLanguageTag(lang)
        val avail = t.isLanguageAvailable(locale)
        if (avail < TextToSpeech.LANG_AVAILABLE) { Log.d("voice: no voice for $lang ($avail)"); return Result.NoVoice }
        t.language = locale
        t.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String) { speaking = true; Log.d("voice: start $lang"); onStart() }
            override fun onDone(id: String) { speaking = false; Log.d("voice: done"); onEnd() }
            @Deprecated("Deprecated in Java") override fun onError(id: String) { speaking = false; Log.d("voice: error"); onEnd() }
            override fun onError(id: String, code: Int) { speaking = false; Log.d("voice: error $code"); onEnd() }
            override fun onStop(id: String, interrupted: Boolean) { speaking = false; onEnd() }
        })
        val r = t.speak(text, TextToSpeech.QUEUE_FLUSH, Bundle(), "said-${System.nanoTime()}")
        return if (r == TextToSpeech.SUCCESS) Result.Spoken else Result.Failed
    }

    fun stop() { tts?.stop() }
}
