package com.shmivan.vpn.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CallSplit
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.PowerSettingsNew
import androidx.compose.material.icons.rounded.Public
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material3.ButtonGroupDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.ShortNavigationBar
import androidx.compose.material3.ShortNavigationBarItem
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.ToggleButton
import androidx.compose.material3.WideNavigationRail
import androidx.compose.material3.WideNavigationRailItem
import androidx.compose.material3.WideNavigationRailValue
import androidx.compose.material3.rememberWideNavigationRailState
import androidx.compose.material3.toPath
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Matrix
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.graphics.shapes.Morph
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.shmivan.vpn.ShmivanVpnService
import com.shmivan.vpn.VpnStatus
import com.shmivan.vpn.core.AppState
import com.shmivan.vpn.core.SplitMode
import com.shmivan.vpn.core.Store

private enum class Tab(val label: String) { HOME("Home"), SERVERS("Servers"), SPLIT("Split tunnel") }

/** Inner screen of a foldable, tablets, landscape: rail navigation and two-pane layouts. */
@Composable
fun isWide(): Boolean = LocalConfiguration.current.screenWidthDp >= 700

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun App(onConnect: () -> Unit, onDisconnect: () -> Unit) {
    val store = Store.get(LocalContext.current)
    val state by store.state.collectAsStateWithLifecycle()
    val status by ShmivanVpnService.status.collectAsStateWithLifecycle()
    var tab by rememberSaveable { mutableStateOf(Tab.HOME) }
    val wide = isWide()

    // Remember what the tunnel was started with, to offer a reconnect after edits.
    var applied by remember { mutableStateOf<AppState?>(null) }
    LaunchedEffect(status is VpnStatus.Connected) { applied = if (status is VpnStatus.Connected) store.state.value else null }
    val needsReconnect = status is VpnStatus.Connected && applied != null && applied != state

    val content: @Composable (Modifier) -> Unit = { modifier ->
        val enterSpec = MaterialTheme.motionScheme.defaultEffectsSpec<Float>()
        val exitSpec = MaterialTheme.motionScheme.fastEffectsSpec<Float>()
        AnimatedContent(
            targetState = tab,
            transitionSpec = { fadeIn(enterSpec) togetherWith fadeOut(exitSpec) },
            modifier = modifier,
            label = "tab",
        ) { current ->
            when (current) {
                Tab.HOME -> HomeScreen(
                    state = state,
                    status = status,
                    wide = wide,
                    needsReconnect = needsReconnect,
                    onToggle = { if (status is VpnStatus.Connected || status is VpnStatus.Connecting) onDisconnect() else onConnect() },
                    onReconnect = { onDisconnect(); onConnect() },
                    onOpenServers = { tab = Tab.SERVERS },
                    onSelectServer = { id -> store.update { it.copy(selectedId = id) } },
                    onSplitMode = { m -> store.update { it.copy(split = it.split.copy(mode = m)) } },
                )
                Tab.SERVERS -> ServersScreen(store, state)
                Tab.SPLIT -> SplitScreen(store, state, wide)
            }
        }
    }

    if (wide) {
        Scaffold { padding ->
            Row(Modifier.padding(padding).fillMaxSize()) {
                WideNavigationRail(
                    state = rememberWideNavigationRailState(WideNavigationRailValue.Expanded),
                    header = { RailHeader() },
                ) {
                    Tab.entries.forEach { t ->
                        WideNavigationRailItem(
                            selected = tab == t,
                            onClick = { tab = t },
                            icon = { Icon(t.icon, null) },
                            label = { Text(t.label) },
                            railExpanded = true,
                        )
                    }
                }
                content(Modifier.weight(1f).fillMaxHeight())
            }
        }
    } else {
        Scaffold(
            bottomBar = {
                ShortNavigationBar {
                    Tab.entries.forEach { t ->
                        ShortNavigationBarItem(selected = tab == t, onClick = { tab = t }, icon = { Icon(t.icon, null) }, label = { Text(t.label) })
                    }
                }
            },
        ) { padding -> content(Modifier.padding(padding)) }
    }
}

private val Tab.icon get() = when (this) { Tab.HOME -> Icons.Rounded.Home; Tab.SERVERS -> Icons.Rounded.Dns; Tab.SPLIT -> Icons.Rounded.CallSplit }

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun RailHeader() {
    Row(Modifier.padding(start = 20.dp, top = 8.dp, bottom = 24.dp), verticalAlignment = Alignment.CenterVertically) {
        Image(
            painterResource(com.shmivan.vpn.R.drawable.ic_launcher_foreground), null,
            Modifier.size(48.dp).clip(MaterialShapes.Cookie9Sided.toShapeCompat()).background(MaterialTheme.colorScheme.primaryContainer),
            contentScale = androidx.compose.ui.layout.ContentScale.Crop,
        )
        Spacer(Modifier.size(12.dp))
        Text("shmivanvpn", style = MaterialTheme.typography.titleLargeEmphasized)
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun HomeScreen(
    state: AppState,
    status: VpnStatus,
    wide: Boolean,
    needsReconnect: Boolean,
    onToggle: () -> Unit,
    onReconnect: () -> Unit,
    onOpenServers: () -> Unit,
    onSelectServer: (String) -> Unit,
    onSplitMode: (SplitMode) -> Unit,
) {
    if (wide) {
        Row(Modifier.fillMaxSize().padding(24.dp), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            // Status pane: the power button gets its own tonal surface, centered.
            Surface(
                shape = MaterialTheme.shapes.extraLarge,
                color = MaterialTheme.colorScheme.surfaceContainerLow,
                modifier = Modifier.weight(1.1f).fillMaxHeight(),
            ) {
                Column(
                    Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) { StatusPane(state, status, needsReconnect, onToggle, onReconnect) }
            }
            Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState()).padding(top = 8.dp)) {
                Text("Server", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(start = 4.dp, bottom = 8.dp))
                ServerQuickList(state, onSelectServer, onOpenServers)
                Spacer(Modifier.height(28.dp))
                Text("Split tunneling", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(start = 4.dp, bottom = 8.dp))
                SplitModeButtons(state.split.mode, onSplitMode)
                Spacer(Modifier.height(12.dp))
                SplitSummary(state)
            }
        }
    } else {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                "shmivanvpn",
                style = MaterialTheme.typography.headlineLargeEmphasized,
                modifier = Modifier.fillMaxWidth().padding(top = 24.dp, bottom = 32.dp),
            )
            StatusPane(state, status, needsReconnect, onToggle, onReconnect)
            Spacer(Modifier.height(32.dp))
            ServerCard(state, onOpenServers)
            Spacer(Modifier.height(20.dp))
            Text("Split tunneling", style = MaterialTheme.typography.titleSmall, modifier = Modifier.fillMaxWidth().padding(start = 4.dp, bottom = 8.dp))
            SplitModeButtons(state.split.mode, onSplitMode)
            Spacer(Modifier.height(24.dp))
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun StatusPane(state: AppState, status: VpnStatus, needsReconnect: Boolean, onToggle: () -> Unit, onReconnect: () -> Unit) {
    ConnectButton(status, onToggle)
    Spacer(Modifier.height(28.dp))
    AnimatedContent(status.title, label = "status") {
        Text(it, style = MaterialTheme.typography.displaySmallEmphasized, textAlign = TextAlign.Center)
    }
    Spacer(Modifier.height(6.dp))
    Text(
        status.subtitle(state),
        style = MaterialTheme.typography.bodyLarge,
        color = if (status is VpnStatus.Failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = TextAlign.Center,
    )
    AnimatedVisibility((status as? VpnStatus.Connected)?.latencyMs != null, enter = scaleIn() + fadeIn(), exit = scaleOut() + fadeOut()) {
        Surface(shape = MaterialTheme.shapes.extraLarge, color = MaterialTheme.colorScheme.tertiaryContainer, modifier = Modifier.padding(top = 12.dp)) {
            Row(Modifier.padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.Speed, null, Modifier.size(18.dp))
                Spacer(Modifier.size(6.dp))
                Text("${(status as? VpnStatus.Connected)?.latencyMs ?: 0} ms", style = MaterialTheme.typography.labelLarge)
            }
        }
    }
    AnimatedVisibility(needsReconnect) {
        FilledTonalButton(onClick = onReconnect, modifier = Modifier.padding(top = 12.dp)) {
            Icon(Icons.Rounded.Refresh, null)
            Spacer(Modifier.size(8.dp))
            Text("Reconnect to apply changes")
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun ServerCard(state: AppState, onOpenServers: () -> Unit) {
    Card(
        onClick = onOpenServers,
        shape = MaterialTheme.shapes.extraLarge,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
        modifier = Modifier.fillMaxWidth(),
    ) {
        ListItem(
            leadingContent = { ServerBadge() },
            headlineContent = { Text(state.selected?.name ?: "No server", style = MaterialTheme.typography.titleMedium) },
            supportingContent = { Text(state.selected?.let { com.shmivan.vpn.core.UriParser.host(it.uri) } ?: "Add a vless:// link") },
            trailingContent = { Icon(Icons.Rounded.ChevronRight, null) },
            colors = ListItemDefaults.colors(containerColor = androidx.compose.ui.graphics.Color.Transparent),
        )
    }
}

/** Wide layout: every server inline as a segmented list, tap to switch. */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun ServerQuickList(state: AppState, onSelect: (String) -> Unit, onOpenServers: () -> Unit) {
    if (state.profiles.isEmpty()) { ServerCard(state, onOpenServers); return }
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        state.profiles.forEachIndexed { i, p ->
            val selected = p.id == state.selected?.id
            Card(
                onClick = { onSelect(p.id) },
                shape = segmentShape(i, state.profiles.lastIndex),
                colors = CardDefaults.cardColors(
                    containerColor = if (selected) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerHigh,
                ),
            ) {
                ListItem(
                    leadingContent = { ServerBadge() },
                    headlineContent = { Text(p.name, style = MaterialTheme.typography.titleMedium) },
                    supportingContent = { Text(com.shmivan.vpn.core.UriParser.host(p.uri) ?: "") },
                    trailingContent = { if (selected) Icon(Icons.Rounded.Check, "Selected") },
                    colors = ListItemDefaults.colors(containerColor = androidx.compose.ui.graphics.Color.Transparent),
                )
            }
        }
    }
}

@Composable
private fun SplitSummary(state: AppState) {
    val s = state.split
    val parts = buildList {
        if (s.apps.isNotEmpty()) add("${s.apps.size} apps")
        if (s.domains.isNotEmpty()) add("${s.domains.size} domains")
        if (s.ips.isNotEmpty()) add("${s.ips.size} IP rules")
        if (s.countries.isNotEmpty()) add(s.countries.joinToString(", ") { it.uppercase() })
        if (s.bypassLan) add("LAN direct")
        if (s.blockAds) add("ads blocked")
    }
    Text(
        if (s.mode == SplitMode.OFF) "Everything goes through the VPN." else parts.joinToString(" · ").ifEmpty { "No rules yet" },
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 4.dp),
    )
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun ServerBadge() {
    Box(
        Modifier.size(44.dp).clip(MaterialShapes.Cookie9Sided.toShapeCompat()).background(MaterialTheme.colorScheme.primaryContainer),
        contentAlignment = Alignment.Center,
    ) { Icon(Icons.Rounded.Public, null, tint = MaterialTheme.colorScheme.onPrimaryContainer) }
}

/** Segmented list shape: large outer corners on the group, small corners between items. */
fun segmentShape(index: Int, last: Int): Shape {
    val big = 28.dp; val small = 6.dp
    return androidx.compose.foundation.shape.RoundedCornerShape(
        topStart = if (index == 0) big else small, topEnd = if (index == 0) big else small,
        bottomStart = if (index == last) big else small, bottomEnd = if (index == last) big else small,
    )
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun SplitModeButtons(mode: SplitMode, onChange: (SplitMode) -> Unit) {
    val options = listOf(SplitMode.OFF to "Off", SplitMode.BYPASS_LISTED to "All but list", SplitMode.ONLY_LISTED to "Only list")
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(ButtonGroupDefaults.ConnectedSpaceBetween)) {
        options.forEachIndexed { i, (m, label) ->
            ToggleButton(
                checked = mode == m,
                onCheckedChange = { onChange(m) },
                modifier = Modifier.weight(1f),
                shapes = when (i) {
                    0 -> ButtonGroupDefaults.connectedLeadingButtonShapes()
                    options.lastIndex -> ButtonGroupDefaults.connectedTrailingButtonShapes()
                    else -> ButtonGroupDefaults.connectedMiddleButtonShapes()
                },
            ) { Text(label, maxLines = 1, autoSize = TextAutoSize.StepBased(minFontSize = 10.sp, maxFontSize = 14.sp)) }
        }
    }
}

/** Big power button: a 9-sided cookie that morphs into a soft burst when connected and spins while connecting. */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun ConnectButton(status: VpnStatus, onClick: () -> Unit) {
    val busy = status is VpnStatus.Connecting || status is VpnStatus.Disconnecting
    val on = status is VpnStatus.Connected
    val morph = remember { Morph(MaterialShapes.Cookie9Sided, MaterialShapes.SoftBurst) }
    val progress by animateFloatAsState(if (on) 1f else 0f, MaterialTheme.motionScheme.slowSpatialSpec(), label = "morph")
    val spin by rememberInfiniteTransition(label = "spin").animateFloat(
        0f, 360f, infiniteRepeatable(tween(if (on) 24_000 else 6_000, easing = LinearEasing), RepeatMode.Restart), label = "spin",
    )
    val scale by animateFloatAsState(if (busy) 0.92f else 1f, MaterialTheme.motionScheme.fastSpatialSpec(), label = "scale")
    val container by animateColorAsState(
        when (status) {
            is VpnStatus.Connected -> MaterialTheme.colorScheme.primary
            is VpnStatus.Failed -> MaterialTheme.colorScheme.errorContainer
            VpnStatus.Connecting, VpnStatus.Disconnecting -> MaterialTheme.colorScheme.secondaryContainer
            VpnStatus.Disconnected -> MaterialTheme.colorScheme.surfaceContainerHighest
        },
        MaterialTheme.motionScheme.defaultEffectsSpec(), label = "color",
    )
    val content = if (on) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface

    Box(Modifier.size(232.dp), contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .size(232.dp)
                .graphicsLayer { scaleX = scale; scaleY = scale; rotationZ = if (on || busy) spin else 0f }
                .clip(MorphShape(morph, progress))
                .background(container)
                .clickable(enabled = !busy, role = Role.Button, onClick = onClick),
        )
        if (busy) {
            LoadingIndicator(Modifier.size(96.dp), color = MaterialTheme.colorScheme.onSecondaryContainer)
        } else {
            Icon(Icons.Rounded.PowerSettingsNew, contentDescription = if (on) "Disconnect" else "Connect", tint = content, modifier = Modifier.size(72.dp))
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
private class MorphShape(private val morph: Morph, private val progress: Float) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val path: Path = morph.toPath(progress)
        path.transform(Matrix().apply { scale(size.width, size.height) })
        val b = path.getBounds()
        path.translate(androidx.compose.ui.geometry.Offset(size.width / 2 - b.center.x, size.height / 2 - b.center.y))
        return Outline.Generic(path)
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
private fun androidx.graphics.shapes.RoundedPolygon.toShapeCompat(): Shape = MorphShape(Morph(this, this), 0f)

private val VpnStatus.title: String
    get() = when (this) {
        VpnStatus.Disconnected -> "Not connected"
        VpnStatus.Connecting -> "Connecting"
        VpnStatus.Disconnecting -> "Disconnecting"
        is VpnStatus.Connected -> "Protected"
        is VpnStatus.Failed -> "Couldn't connect"
    }

private fun VpnStatus.subtitle(state: AppState): String = when (this) {
    is VpnStatus.Failed -> message
    is VpnStatus.Connected -> "Through $serverName"
    else -> if (state.profiles.isEmpty()) "Add a server to get started" else "Tap to connect"
}

