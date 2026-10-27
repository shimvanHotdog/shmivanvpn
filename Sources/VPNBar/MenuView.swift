import SwiftUI

struct MenuView: View {
    @EnvironmentObject var vpn: VPNController
    var openSettings: () -> Void = {}
    var openBenchmark: () -> Void = {}

    var body: some View {
        VStack(spacing: 16) {
            header
            serverCard
            modeSwitch
            splitCard
            toolbar
        }
        .padding(18)
        .frame(width: 300)
        .animation(.smooth(duration: 0.3), value: vpn.status)
        .animation(.smooth(duration: 0.3), value: vpn.settings.split.enabled)
    }

    // MARK: - Power button + status

    private var header: some View {
        VStack(spacing: 10) {
            Button(action: vpn.toggle) {
                Image(systemName: "power")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(vpn.status == .connected ? .white : .primary)
                    .symbolEffect(.pulse, isActive: isBusy)
                    .frame(width: 84, height: 84)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(powerTint).interactive(), in: .circle)
            .disabled(isBusy)
            .help(vpn.isActive ? "Disconnect" : "Connect")

            VStack(spacing: 3) {
                Text(statusTitle)
                    .font(.title3.weight(.semibold))
                    .contentTransition(.opacity)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(isFailed ? .red : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let check = vpn.lastCheck {
                Label(check, systemImage: "location.fill")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Server picker

    private var serverCard: some View {
        Menu {
            ForEach(vpn.settings.profiles) { p in
                Button {
                    vpn.settings.selectedProfileID = p.id
                    vpn.reconnectIfActive()
                } label: {
                    if p.id == vpn.selectedProfile?.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
            Divider()
            Button("Paste link from clipboard", systemImage: "doc.on.clipboard", action: pasteLink)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(vpn.selectedProfile?.name ?? "No server")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(vpn.selectedProfile.flatMap { URIParser.host(of: $0.uri) } ?? "Paste a vless:// link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 16))
    }

    // MARK: - Mode switch

    private var modeSwitch: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(ConnectionMode.allCases) { mode in
                    let selected = vpn.settings.mode == mode
                    Button {
                        guard !selected else { return }
                        vpn.settings.mode = mode
                        if vpn.isActive { vpn.reconnectIfActive() }
                    } label: {
                        Label(mode.shortTitle, systemImage: mode.symbol)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(selected ? .regular.tint(.accentColor.opacity(0.45)).interactive() : .regular.interactive(),
                                 in: .capsule)
                }
            }
        }
        .animation(.bouncy, value: vpn.settings.mode)
    }

    // MARK: - Split tunneling

    private var splitCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { vpn.settings.split.enabled },
                set: { vpn.settings.split.enabled = $0; vpn.reconnectIfActive() }
            )) {
                Label("Split tunneling", systemImage: "arrow.triangle.branch")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if vpn.settings.split.enabled {
                Picker("", selection: Binding(
                    get: { vpn.settings.split.mode },
                    set: { vpn.settings.split.mode = $0; vpn.reconnectIfActive() }
                )) {
                    Text("All except list").tag(SplitTunnelSettings.Mode.bypassListed)
                    Text("Only the list").tag(SplitTunnelSettings.Mode.onlyListed)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 16))
    }

    // MARK: - Bottom actions

    private var toolbar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                toolButton("gauge.with.needle", "Check connection") { vpn.checkConnection() }
                    .disabled(vpn.status != .connected)
                toolButton("doc.on.clipboard", "Paste link", action: pasteLink)
                toolButton("speedometer", "Benchmark & report for the server admin", action: openBenchmark)
                Spacer()
                toolButton("gearshape", "Settings", action: openSettings)
                toolButton("xmark", "Quit") { NSApp.terminate(nil) }
            }
        }
    }

    private func toolButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 34)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
    }

    // MARK: - Helpers

    private func pasteLink() {
        vpn.importLinks(from: NSPasteboard.general.string(forType: .string) ?? "")
    }

    private var isBusy: Bool { vpn.status == .connecting || vpn.status == .disconnecting }
    private var isFailed: Bool { if case .failed = vpn.status { return true } else { return false } }

    private var powerTint: Color? {
        switch vpn.status {
        case .connected: return .green.opacity(0.75)
        case .connecting, .disconnecting: return .orange.opacity(0.5)
        case .failed: return .red.opacity(0.45)
        case .disconnected: return nil
        }
    }

    private var statusTitle: String {
        switch vpn.status {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        case .connected: return "Protected"
        case .failed: return "Connection failed"
        }
    }

    private var statusDetail: String {
        switch vpn.status {
        case .failed(let msg): return msg
        case .connected: return vpn.settings.mode.title
        default: return Brand.name
        }
    }
}

extension ConnectionMode {
    var shortTitle: String { self == .systemProxy ? "Proxy" : "Full VPN" }
    var symbol: String { self == .systemProxy ? "network" : "lock.shield" }
}
