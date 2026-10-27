package com.shmivan.vpn

import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Quick Settings toggle. */
class VpnTileService : TileService() {
    override fun onStartListening() {
        val tile = qsTile ?: return
        val status = ShmivanVpnService.status.value
        tile.state = when (status) {
            is VpnStatus.Connected, VpnStatus.Connecting -> Tile.STATE_ACTIVE
            else -> Tile.STATE_INACTIVE
        }
        tile.subtitle = (status as? VpnStatus.Connected)?.serverName
        tile.updateTile()
    }

    override fun onClick() {
        when (ShmivanVpnService.status.value) {
            is VpnStatus.Connected, VpnStatus.Connecting -> ShmivanVpnService.stop(this)
            else -> if (VpnService.prepare(this) == null) {
                ShmivanVpnService.start(this)
            } else {
                // First use needs the system VPN consent dialog, which only an activity can show.
                val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
            }
        }
        qsTile?.apply { state = if (state == Tile.STATE_ACTIVE) Tile.STATE_INACTIVE else Tile.STATE_ACTIVE; updateTile() }
    }
}
