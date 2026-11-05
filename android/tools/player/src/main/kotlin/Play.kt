package com.wquguru.cicada.player

import android.app.Activity
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Bundle
import android.widget.TextView

/// Plays the intent's file or URL once as media, the way a video or podcast app does.
class Play : Activity() {
    private var player: MediaPlayer? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uri = intent.data ?: return finish()
        setContentView(TextView(this).apply { text = "Playing $uri"; textSize = 20f; setPadding(48, 200, 48, 48) })
        player = MediaPlayer().apply {
            setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            setDataSource(this@Play, uri)
            setOnCompletionListener { finish() }
            prepare(); start()
        }
    }

    override fun onDestroy() { player?.release(); super.onDestroy() }
}
