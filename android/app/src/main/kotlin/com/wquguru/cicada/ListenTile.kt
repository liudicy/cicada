package com.wquguru.cicada

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import cicada.Strings.L

/// The 知了 tile in Quick Settings: one tap starts listening (from the source chosen last time) or
/// ends it, without opening the app first. Lit while listening, with the time as its subtitle.
class ListenTile : TileService() {
    // While Quick Settings is open the tile is updated directly (a refresh request is ignored for a
    // tile already showing), and its clock ticks.
    private val tick = object : Runnable {
        override fun run() { update(); if (cicada.listen.listening) cicada.main.postDelayed(this, 1000) }
    }

    override fun onStartListening() { visible = this; cicada.main.removeCallbacks(tick); cicada.main.post(tick) }

    override fun onStopListening() { if (visible === this) visible = null; cicada.main.removeCallbacks(tick) }

    override fun onClick() {
        val app = cicada
        if (app.listen.listening) { app.stopListening { update() }; return }
        val intent = app.startIntent(this, app.settings.source) ?: return
        // A tile may only open an activity by collapsing the panel; Android 14+ takes a PendingIntent.
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 3, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private fun update() {
        val tile = qsTile ?: return
        val app = cicada
        val listening = app.listen.listening
        tile.state = if (listening) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = L("知了")
        tile.subtitle = when {
            listening -> NotesViews.status(app)
            app.settings.source == "mic" -> L("面对面")
            else -> L("手机里的声音")
        }
        tile.contentDescription = if (listening) L("结束") else L("开始听")
        tile.icon = Icon.createWithResource(this, R.drawable.ic_notification)
        tile.updateTile()
    }

    companion object {
        @Volatile private var visible: ListenTile? = null

        /// Listening started or ended: update the tile now if it is showing, else ask the system to.
        fun refresh(context: Context) {
            visible?.let { it.cicada.main.post(it.tick); return }
            try { requestListeningState(context, ComponentName(context, ListenTile::class.java)) } catch (_: Exception) {}
        }
    }
}
