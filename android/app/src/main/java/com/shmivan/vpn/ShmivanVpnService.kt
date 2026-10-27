package com.shmivan.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.service.quicksettings.TileService
import android.util.Log
import com.shmivan.vpn.core.SplitMode
import com.shmivan.vpn.core.Store
import com.shmivan.vpn.core.XrayConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import libv2ray.CoreCallbackHandler
import libv2ray.CoreController
import libv2ray.Libv2ray
import java.io.File

sealed interface VpnStatus {
    data object Disconnected : VpnStatus
    data object Connecting : VpnStatus
    data class Connected(val serverName: String, val latencyMs: Long? = null) : VpnStatus
    data object Disconnecting : VpnStatus
    data class Failed(val message: String) : VpnStatus
}

/** Runs Xray (libv2ray) on the TUN file descriptor provided by Android's VpnService. */
class ShmivanVpnService : VpnService(), CoreCallbackHandler {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var tun: ParcelFileDescriptor? = null
    private var core: CoreController? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> scope.launch { stopVpn() }
            else -> {
                startForegroundCompat(getString(R.string.connecting))
                scope.launch { startVpn() }
            }
        }
        return START_NOT_STICKY
    }

    private fun startVpn() {
        val state = Store.get(this).state.value
        val profile = state.selected ?: return fail("Add a server first")
        _status.value = VpnStatus.Connecting
        stopCore()
        try {
            val config = XrayConfig.build(profile, state.split)
            Libv2ray.initCoreEnv(prepareAssets().path, "")

            val builder = Builder()
                .setSession(profile.name)
                .setMtu(1500)
                .addAddress("10.10.14.1", 30)
                .addRoute("0.0.0.0", 0)
                .addAddress("fd00:10:10:14::1", 126)
                .addRoute("::", 0)
                .addDnsServer("1.1.1.1")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

            // Per-app split tunneling is native: Android keeps excluded apps out of the tunnel.
            // This app is always excluded so Xray's own connection to the server never loops back in.
            val apps = state.split.apps.filter { it != packageName && isInstalled(it) }
            if (state.split.mode == SplitMode.ONLY_LISTED && apps.isNotEmpty()) {
                apps.forEach { builder.addAllowedApplication(it) }
            } else {
                builder.addDisallowedApplication(packageName)
                if (state.split.mode == SplitMode.BYPASS_LISTED) apps.forEach { builder.addDisallowedApplication(it) }
            }

            val fd = builder.establish() ?: return fail("VPN permission was revoked")
            tun = fd
            core = Libv2ray.newCoreController(this).also { it.startLoop(config, fd.fd) }
            if (core?.isRunning != true) return fail("Xray failed to start")

            _status.value = VpnStatus.Connected(profile.name)
            updateNotification(getString(R.string.connected_to, profile.name))
            TileService.requestListeningState(this, android.content.ComponentName(this, VpnTileService::class.java))
            measureLatency(profile.name)
        } catch (e: Exception) {
            Log.e(TAG, "start failed", e)
            fail(e.message ?: e.javaClass.simpleName)
        }
    }

    fun measureLatency(name: String) = scope.launch {
        val ms = runCatching { core?.measureDelay("https://www.gstatic.com/generate_204") }.getOrNull()
        if (_status.value is VpnStatus.Connected) _status.value = VpnStatus.Connected(name, ms?.takeIf { it > 0 })
    }

    private fun stopVpn() {
        _status.value = VpnStatus.Disconnecting
        stopCore()
        _status.value = VpnStatus.Disconnected
        TileService.requestListeningState(this, android.content.ComponentName(this, VpnTileService::class.java))
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun stopCore() {
        runCatching { core?.stopLoop() }
        core = null
        runCatching { tun?.close() }
        tun = null
    }

    private fun fail(message: String) {
        stopCore()
        _status.value = VpnStatus.Failed(message)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onRevoke() {
        scope.launch { stopVpn() }
    }

    override fun onDestroy() {
        stopCore()
        if (_status.value !is VpnStatus.Failed) _status.value = VpnStatus.Disconnected
        scope.cancel()
        super.onDestroy()
    }

    /** geoip.dat / geosite.dat ship as assets; Xray reads them from disk. */
    private fun prepareAssets(): File {
        val dir = File(filesDir, "xray").apply { mkdirs() }
        for (name in listOf("geoip.dat", "geosite.dat")) {
            val out = File(dir, name)
            val size = assets.openFd(name).use { it.length }
            if (out.length() != size) assets.open(name).use { input -> out.outputStream().use { input.copyTo(it) } }
        }
        return dir
    }

    private fun isInstalled(pkg: String) = runCatching { packageManager.getPackageInfo(pkg, 0) }.isSuccess

    // MARK: notification

    private fun notification(text: String): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, getString(R.string.app_name), NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, ShmivanVpnService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_tile)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, getString(R.string.disconnect), stop).build())
            .build()
    }

    private fun startForegroundCompat(text: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification(text), ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
        } else {
            startForeground(NOTIFICATION_ID, notification(text))
        }
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(text))
    }

    // MARK: CoreCallbackHandler (called from Go)

    override fun startup(): Long = 0
    override fun shutdown(): Long = 0
    override fun onEmitStatus(code: Long, message: String?): Long {
        Log.i(TAG, "core: $message")
        return 0
    }

    companion object {
        private const val TAG = "shmivanvpn"
        private const val CHANNEL = "vpn"
        private const val NOTIFICATION_ID = 1
        const val ACTION_STOP = "com.shmivan.vpn.STOP"

        private val _status = MutableStateFlow<VpnStatus>(VpnStatus.Disconnected)
        val status: StateFlow<VpnStatus> = _status

        /** Caller must have obtained VPN consent (VpnService.prepare == null). */
        fun start(context: Context) {
            context.startForegroundService(Intent(context, ShmivanVpnService::class.java))
        }

        fun stop(context: Context) {
            context.startService(Intent(context, ShmivanVpnService::class.java).setAction(ACTION_STOP))
        }
    }
}
