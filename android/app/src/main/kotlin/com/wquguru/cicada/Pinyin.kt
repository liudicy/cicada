package com.wquguru.cicada

/// Toneless pinyin for Correction.soundsAlike, from the phone's own ICU (Android 7+): the Mac reads
/// it from the system's Mandarin transform, one character at a time, and so does this. The CLI's
/// tests use a table generated from the Mac's transform; `cicadactl.sh pinyin <text>` compares.
object Pinyin {
    private val transform by lazy { android.icu.text.Transliterator.getInstance("Han-Latin; Latin-ASCII") }
    private val cache = HashMap<Char, String>()

    fun of(c: Char): String {
        if (!Character.isIdeographic(c.code)) return ""
        synchronized(cache) { cache[c]?.let { return it } }
        val s = synchronized(transform) { transform.transliterate(c.toString()) }.trim().lowercase()
        // A character ICU can't read comes back as itself: no syllable.
        val out = if (s.any { it.code >= 128 } ) "" else s
        synchronized(cache) { if (cache.size < 5000) cache[c] = out }
        return out
    }
}
