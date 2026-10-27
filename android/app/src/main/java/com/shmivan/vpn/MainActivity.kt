package com.shmivan.vpn

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import android.widget.Toast
import com.shmivan.vpn.core.Store
import com.shmivan.vpn.ui.App
import com.shmivan.vpn.ui.ShmivanTheme

class MainActivity : ComponentActivity() {
    private val vpnConsent = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        if (it.resultCode == RESULT_OK) ShmivanVpnService.start(this)
    }
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        importLink(intent)
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)

        setContent {
            ShmivanTheme {
                App(onConnect = ::connect, onDisconnect = { ShmivanVpnService.stop(this) })
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        importLink(intent)
    }

    private fun importLink(intent: Intent?) {
        val link = intent?.takeIf { it.action == Intent.ACTION_VIEW }?.dataString ?: return
        val added = Store.get(this).importLinks(link)
        Toast.makeText(this, if (added > 0) "Server added" else "Server already added or link not supported", Toast.LENGTH_SHORT).show()
    }

    private fun connect() {
        val consent = VpnService.prepare(this)
        if (consent != null) vpnConsent.launch(consent) else ShmivanVpnService.start(this)
    }
}
