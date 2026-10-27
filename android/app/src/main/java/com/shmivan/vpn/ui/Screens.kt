package com.shmivan.vpn.ui

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Apps
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SmallFloatingActionButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.core.graphics.drawable.toBitmap
import com.shmivan.vpn.core.AppState
import com.shmivan.vpn.core.SplitMode
import com.shmivan.vpn.core.Store
import com.shmivan.vpn.core.UriParser
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// MARK: - Servers

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ServersScreen(store: Store, state: AppState) {
    val context = LocalContext.current
    var message by remember { mutableStateOf<String?>(null) }
    var showAdd by remember { mutableStateOf(false) }

    fun import(text: String) {
        val n = store.importLinks(text)
        message = if (n == 0) "No new vless://, http://, https:// or socks:// links found" else "Added $n server(s)"
    }

    Scaffold(
        floatingActionButton = {
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                SmallFloatingActionButton(onClick = { showAdd = true }) { Icon(Icons.Rounded.Add, "Add link") }
                ExtendedFloatingActionButton(
                    onClick = {
                        val clip = context.getSystemService(ClipboardManager::class.java).primaryClip
                        import(clip?.getItemAt(0)?.coerceToText(context)?.toString() ?: "")
                    },
                    icon = { Icon(Icons.Rounded.ContentPaste, null) },
                    text = { Text("Paste link") },
                )
            }
        },
    ) { inner ->
        LazyColumn(
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = inner.calculateTopPadding() + 24.dp, bottom = 160.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
            modifier = Modifier.fillMaxSize().wrapContentWidth().widthIn(max = 760.dp),
        ) {
            item {
                Text("Servers", style = MaterialTheme.typography.headlineLargeEmphasized, modifier = Modifier.padding(start = 4.dp, bottom = 4.dp))
                message?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 4.dp, bottom = 12.dp)) }
            }
            if (state.profiles.isEmpty()) item {
                Text(
                    "Copy a vless:// link from your 3x-ui panel, then tap Paste link.",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(4.dp),
                )
            }
            items(state.profiles, key = { it.id }) { p ->
                val selected = p.id == state.selected?.id
                Card(
                    onClick = { store.update { it.copy(selectedId = p.id) } },
                    shape = segmentShape(state.profiles.indexOf(p), state.profiles.lastIndex),
                    colors = CardDefaults.cardColors(
                        containerColor = if (selected) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerHigh,
                    ),
                ) {
                    ListItem(
                        leadingContent = { RadioButton(selected = selected, onClick = { store.update { it.copy(selectedId = p.id) } }) },
                        headlineContent = { Text(p.name, style = MaterialTheme.typography.titleMedium) },
                        supportingContent = {
                            Text("${p.uri.substringBefore(':').uppercase()} · ${UriParser.host(p.uri) ?: "?"}")
                        },
                        trailingContent = {
                            IconButton(onClick = { store.update { s -> s.copy(profiles = s.profiles - p, selectedId = s.selectedId.takeIf { it != p.id }) } }) {
                                Icon(Icons.Rounded.Delete, "Remove")
                            }
                        },
                        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                    )
                }
            }
        }
    }

    if (showAdd) {
        var text by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { showAdd = false },
            title = { Text("Add server") },
            text = {
                OutlinedTextField(
                    value = text, onValueChange = { text = it },
                    label = { Text("vless:// or http(s):// or socks:// link") },
                    minLines = 3,
                    textStyle = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                )
            },
            confirmButton = { TextButton(onClick = { import(text); showAdd = false }, enabled = text.isNotBlank()) { Text("Add") } },
            dismissButton = { TextButton(onClick = { showAdd = false }) { Text("Cancel") } },
        )
    }
}

// MARK: - Split tunneling

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun SplitScreen(store: Store, state: AppState, wide: Boolean) {
    val split = state.split
    var countries by remember { mutableStateOf(split.countries.joinToString(", ")) }
    var domains by remember { mutableStateOf(split.domains.joinToString("\n")) }
    var ips by remember { mutableStateOf(split.ips.joinToString("\n")) }
    var pickApps by remember { mutableStateOf(false) }
    fun lines(s: String) = s.split('\n').map { it.trim() }.filter { it.isNotEmpty() }

    val modeSection: @Composable () -> Unit = {
        SplitModeButtons(split.mode) { m -> store.update { it.copy(split = it.split.copy(mode = m)) } }
        Text(
            when (split.mode) {
                SplitMode.OFF -> "Everything goes through the VPN."
                SplitMode.BYPASS_LISTED -> "Everything goes through the VPN except the apps, domains and IPs below."
                SplitMode.ONLY_LISTED -> "Only the apps, domains and IPs below go through the VPN."
            },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 4.dp, top = 10.dp),
        )
    }
    val quickRules: @Composable () -> Unit = {
        Section {
            SwitchRow("Local network always direct", split.bypassLan) { v -> store.update { it.copy(split = it.split.copy(bypassLan = v)) } }
            SwitchRow("Block ads", split.blockAds) { v -> store.update { it.copy(split = it.split.copy(blockAds = v)) } }
        }
        Section {
            ListItem(
                headlineContent = { Text("Apps", style = MaterialTheme.typography.titleMedium) },
                supportingContent = { Text(if (split.apps.isEmpty()) "None selected" else "${split.apps.size} selected") },
                leadingContent = { Icon(Icons.Rounded.Apps, null) },
                trailingContent = { FilledTonalButton(onClick = { pickApps = true }) { Text("Choose") } },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            )
        }
        OutlinedTextField(
            value = countries,
            onValueChange = { countries = it; store.update { s -> s.copy(split = s.split.copy(countries = it.split(',', ' ', '\n').filter(String::isNotBlank))) } },
            label = { Text("Countries") }, placeholder = { Text("ru, cn") },
            supportingText = { Text("All IPs and .cc domains of these countries") },
            singleLine = true, shape = MaterialTheme.shapes.large, modifier = Modifier.fillMaxWidth(),
        )
    }
    val lists: @Composable () -> Unit = {
        OutlinedTextField(
            value = domains,
            onValueChange = { domains = it; store.update { s -> s.copy(split = s.split.copy(domains = lines(it))) } },
            label = { Text("Domains") }, placeholder = { Text("example.com\ngeosite:netflix") },
            supportingText = { Text("One per line; covers subdomains") },
            minLines = if (wide) 8 else 3, shape = MaterialTheme.shapes.large, modifier = Modifier.fillMaxWidth(),
            textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
        )
        OutlinedTextField(
            value = ips,
            onValueChange = { ips = it; store.update { s -> s.copy(split = s.split.copy(ips = lines(it))) } },
            label = { Text("IPs / CIDR") }, placeholder = { Text("10.0.0.0/8\ngeoip:de") },
            minLines = if (wide) 6 else 3, shape = MaterialTheme.shapes.large, modifier = Modifier.fillMaxWidth(),
            textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
        )
    }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = if (wide) 24.dp else 16.dp, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Split tunneling", style = MaterialTheme.typography.headlineLargeEmphasized, modifier = Modifier.padding(start = 4.dp))
        Column { modeSection() }
        if (split.mode != SplitMode.OFF) {
            if (wide) {
                Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(16.dp)) { quickRules() }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(16.dp)) { lists() }
                }
            } else {
                quickRules()
                lists()
            }
        }
    }

    if (pickApps) AppPicker(split.apps, onDismiss = { pickApps = false }) { selected ->
        store.update { it.copy(split = it.split.copy(apps = selected)) }
    }
}

@Composable
private fun Section(content: @Composable () -> Unit) {
    Card(shape = MaterialTheme.shapes.extraLarge, colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh)) {
        Column(Modifier.padding(vertical = 4.dp)) { content() }
    }
}

@Composable
private fun SwitchRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    ListItem(
        headlineContent = { Text(label) },
        trailingContent = { Switch(checked = checked, onCheckedChange = onChange) },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = Modifier.fillMaxWidth(),
    )
}

private data class AppInfo(val pkg: String, val label: String, val icon: ImageBitmap)

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun AppPicker(initial: List<String>, onDismiss: () -> Unit, onChange: (List<String>) -> Unit) {
    val context = LocalContext.current
    var apps by remember { mutableStateOf<List<AppInfo>?>(null) }
    var selected by remember { mutableStateOf(initial.toSet()) }
    var query by remember { mutableStateOf("") }
    LaunchedEffect(Unit) { apps = withContext(Dispatchers.IO) { launchableApps(context) } }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxHeight(0.92f).padding(horizontal = 16.dp)) {
            Text("Choose apps", style = MaterialTheme.typography.headlineSmallEmphasized, modifier = Modifier.padding(bottom = 12.dp))
            OutlinedTextField(
                value = query, onValueChange = { query = it },
                leadingIcon = { Icon(Icons.Rounded.Search, null) }, placeholder = { Text("Search") },
                singleLine = true, shape = MaterialTheme.shapes.extraLarge, modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(8.dp))
            val list = apps
            if (list == null) {
                Box(Modifier.fillMaxWidth().padding(48.dp), contentAlignment = Alignment.Center) { LoadingIndicator() }
            } else {
                val shown = list.filter { query.isBlank() || it.label.contains(query, true) || it.pkg.contains(query, true) }
                    .sortedWith(compareByDescending<AppInfo> { it.pkg in selected }.thenBy { it.label.lowercase() })
                LazyColumn(Modifier.fillMaxWidth()) {
                    items(shown, key = { it.pkg }) { app ->
                        val checked = app.pkg in selected
                        fun toggle() {
                            selected = if (checked) selected - app.pkg else selected + app.pkg
                            onChange(selected.toList())
                        }
                        ListItem(
                            leadingContent = { Image(app.icon, null, Modifier.size(40.dp)) },
                            headlineContent = { Text(app.label) },
                            supportingContent = { Text(app.pkg, style = MaterialTheme.typography.bodySmall) },
                            trailingContent = { Checkbox(checked = checked, onCheckedChange = { toggle() }) },
                            colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                        )
                    }
                }
            }
        }
    }
}

private fun launchableApps(context: Context): List<AppInfo> {
    val pm = context.packageManager
    val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
    return pm.queryIntentActivities(intent, PackageManager.MATCH_ALL)
        .map { it.activityInfo.applicationInfo }
        .filter { it.packageName != context.packageName }
        .distinctBy { it.packageName }
        .map { AppInfo(it.packageName, it.loadLabel(pm).toString(), it.loadIcon(pm).toBitmap(96, 96).asImageBitmap()) }
}
