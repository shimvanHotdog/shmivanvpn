import Combine
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPage: String, CaseIterable, Identifiable {
    case servers, split, benchmark, general, logs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .servers: return "Servers"
        case .split: return "Split Tunneling"
        case .benchmark: return "Benchmark"
        case .general: return "General"
        case .logs: return "Logs"
        }
    }
    var symbol: String {
        switch self {
        case .servers: return "server.rack"
        case .split: return "arrow.triangle.branch"
        case .benchmark: return "speedometer"
        case .general: return "gearshape"
        case .logs: return "text.alignleft"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var vpn: VPNController
    @ObservedObject private var nav = SettingsNav.shared

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $nav.page) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            let page = nav.page ?? .servers
            Group {
                switch page {
                case .servers: ServersTab()
                case .split: SplitTunnelTab()
                case .benchmark: BenchmarkTab()
                case .general: GeneralTab()
                case .logs: LogsTab()
                }
            }
            .navigationTitle(page.title)
        }
        .frame(minWidth: 780, minHeight: 560)
    }
}

// MARK: - Servers

private struct ServersTab: View {
    @EnvironmentObject var vpn: VPNController
    @StateObject private var ui = ServersUI()

    var body: some View {
        Form {
            Section {
                if vpn.settings.profiles.isEmpty {
                    Text("No servers yet. Paste a vless:// link below.").foregroundStyle(.secondary)
                }
                ForEach($vpn.settings.profiles) { $p in
                    let selected = p.id == vpn.selectedProfile?.id
                    HStack(spacing: 12) {
                        Button {
                            vpn.settings.selectedProfileID = p.id
                            vpn.reconnectIfActive()
                        } label: {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Name", text: $p.name).textFieldStyle(.plain).font(.body.weight(.medium))
                            Text(URIParser.host(of: p.uri) ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(p.uri.split(separator: ":").first.map { String($0).uppercased() } ?? "")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .glassEffect(.regular, in: .capsule)
                        Button(role: .destructive) { vpn.removeProfile(p) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove server")
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Servers")
            }

            Section {
                TextField("Link", text: $ui.newLink, prompt: Text("vless://…  or  http://user:pass@host:port"))
                HStack {
                    Button("Import file…", systemImage: "square.and.arrow.down", action: importFile)
                        .buttonStyle(.glass)
                    Button("Paste", systemImage: "doc.on.clipboard") { add(NSPasteboard.general.string(forType: .string) ?? "") }
                        .buttonStyle(.glass)
                    Spacer()
                    if let message = ui.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Button("Add") { add(ui.newLink); ui.newLink = "" }
                        .buttonStyle(.glassProminent)
                        .disabled(ui.newLink.isEmpty)
                }
            } header: {
                Text("Add server")
            } footer: {
                Text("Accepts 3x-ui share links (vless://) and http://, https://, socks:// proxies. Import reads every link in a .env or text file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func add(_ text: String) {
        let n = vpn.importLinks(from: text)
        ui.message = n == 0 ? "No new supported links found" : "Added \(n) server(s)"
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.allowedContentTypes = [.data, .text]
        if panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) {
            add(text)
        }
    }
}

// MARK: - Split tunneling

private struct SplitTunnelTab: View {
    @EnvironmentObject var vpn: VPNController
    @StateObject private var ui = SplitUI()

    var body: some View {
        Form {
            Section {
                Toggle("Enable split tunneling", isOn: $ui.draft.enabled)
                Picker("Send through VPN", selection: $ui.draft.mode) {
                    Text("Everything except the list").tag(SplitTunnelSettings.Mode.bypassListed)
                    Text("Only the list").tag(SplitTunnelSettings.Mode.onlyListed)
                }
                .pickerStyle(.segmented)
                .disabled(!ui.draft.enabled)
            } footer: {
                Text(ui.draft.mode == .bypassListed
                     ? "Entries below go direct, outside the VPN."
                     : "Only entries below go through the VPN; everything else is direct.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Group {
                Section("Quick rules") {
                    Toggle("Local network always direct", isOn: $ui.draft.bypassLAN)
                    Toggle("Block ads", isOn: $ui.draft.blockAds)
                    TextField("Countries", text: $ui.countries, prompt: Text("ru, cn"))
                }
                Section {
                    ListEditor(hint: "example.com\ngeosite:netflix\nkeyword:bank", text: $ui.domains)
                } header: { Text("Domains") } footer: {
                    Text("One per line. example.com also covers its subdomains.").font(.caption).foregroundStyle(.secondary)
                }
                Section("IPs / CIDR") {
                    ListEditor(hint: "1.2.3.4\n10.8.0.0/16\ngeoip:de", text: $ui.ips)
                }
                Section {
                    ListEditor(hint: "/Applications/Telegram.app", text: $ui.apps)
                    Button("Add app…", systemImage: "plus.app", action: pickApp).buttonStyle(.glass)
                } header: { Text("Apps") } footer: {
                    Text("App rules work best in Full VPN mode.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!ui.draft.enabled)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            GlassEffectContainer {
                HStack {
                    Spacer()
                    Button("Revert", action: load).buttonStyle(.glass)
                    Button("Save") {
                        vpn.settings.split = edited
                        vpn.reconnectIfActive()
                    }
                    .keyboardShortcut("s")
                    .buttonStyle(.glassProminent)
                    .disabled(edited == vpn.settings.split)
                }
                .controlSize(.large)
                .padding(16)
            }
        }
        .onAppear { if !ui.loaded { load(); ui.loaded = true } }
    }

    private var edited: SplitTunnelSettings {
        var s = ui.draft
        s.countries = Self.split(ui.countries, by: CharacterSet(charactersIn: ", \n"))
        s.domains = Self.split(ui.domains, by: .newlines)
        s.ips = Self.split(ui.ips, by: .newlines)
        s.apps = Self.split(ui.apps, by: .newlines)
        return s
    }

    private func load() {
        ui.draft = vpn.settings.split
        ui.countries = ui.draft.countries.joined(separator: ", ")
        ui.domains = ui.draft.domains.joined(separator: "\n")
        ui.ips = ui.draft.ips.joined(separator: "\n")
        ui.apps = ui.draft.apps.joined(separator: "\n")
    }

    private static func split(_ text: String, by set: CharacterSet) -> [String] {
        text.components(separatedBy: set).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let existing = Self.split(ui.apps, by: .newlines)
        let added = panel.urls.map(\.path).filter { !existing.contains($0) }
        ui.apps = (existing + added).joined(separator: "\n")
    }
}

private struct ListEditor: View {
    let hint: String
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
            if text.isEmpty {
                Text(hint).font(.system(.callout, design: .monospaced)).foregroundStyle(.tertiary)
                    .padding(.leading, 5).allowsHitTesting(false)
            }
        }
        .frame(minHeight: 90)
    }
}

// MARK: - Benchmark

private struct BenchmarkTab: View {
    @EnvironmentObject var vpn: VPNController
    @EnvironmentObject var bench: Benchmark

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(vpn.selectedProfile?.name ?? "No server").font(.headline)
                        Text("DNS, ping, TLS, direct vs VPN latency, download and upload. Takes about a minute and transfers ~350 MB.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(bench.isRunning ? "Running…" : "Run benchmark", systemImage: "play.fill") {
                        if let p = vpn.selectedProfile { bench.run(profile: p, settings: vpn.settings, vpnActive: vpn.isActive) }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(bench.isRunning || vpn.selectedProfile == nil)
                }
            }

            if !bench.steps.isEmpty {
                Section("Progress") {
                    ForEach(bench.steps) { step in
                        HStack(spacing: 10) {
                            Group {
                                switch step.state {
                                case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                                case .running: ProgressView().controlSize(.small)
                                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                                }
                            }
                            .frame(width: 18)
                            Text(step.title)
                            Spacer()
                            Text(step.detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }

            if !bench.report.isEmpty {
                Section {
                    ScrollView {
                        Text(bench.report)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 220)
                    HStack {
                        Button("Copy", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(bench.report, forType: .string)
                        }
                        .buttonStyle(.glass)
                        ShareLink(item: bench.report, subject: Text("\(Brand.name) connection report")) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.glass)
                        Button("Save…", systemImage: "square.and.arrow.down", action: save)
                            .buttonStyle(.glass)
                    }
                } header: {
                    Text("Report for the server admin")
                } footer: {
                    Text("The UUID is masked. The report includes your public IP and the server address/path.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(Brand.name)-report-\(Date().formatted(.iso8601.year().month().day())).txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url { try? bench.report.write(to: url, atomically: true, encoding: .utf8) }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var vpn: VPNController

    var body: some View {
        Form {
            Section {
                Picker("Connection mode", selection: $vpn.settings.mode) {
                    ForEach(ConnectionMode.allCases) { Text($0.shortTitle).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Proxy covers apps that use the macOS proxy settings (browsers, most apps) and needs no admin rights. Full VPN covers all traffic, including terminal tools and games, and needs the helper below.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("TUN helper") {
                HStack {
                    Label(vpn.helperInstalled ? "Installed" : "Not installed",
                          systemImage: vpn.helperInstalled ? "checkmark.seal.fill" : "xmark.seal")
                    Spacer()
                    if vpn.helperInstalled { Button("Uninstall") { vpn.uninstallHelper() }.buttonStyle(.glass) }
                    Button(vpn.helperInstalled ? "Reinstall" : "Install…") { vpn.installHelper() }.buttonStyle(.glassProminent)
                }
                Text("Asks for your password once. Installs xray to /Library/PrivilegedHelperTools and a sudoers rule so \(Brand.name) can start TUN without prompting. Reinstall after updating the app.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Route system DNS through the VPN (prevents DNS leaks)", isOn: $vpn.settings.tunPreventDNSLeak)
            }

            Section("Local proxy ports") {
                TextField("SOCKS5", value: $vpn.settings.socksPort, format: .number.grouping(.never))
                TextField("HTTP", value: $vpn.settings.httpPort, format: .number.grouping(.never))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Logs

private struct LogsTab: View {
    @EnvironmentObject var vpn: VPNController
    @StateObject private var ui = LogsUI()
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            Text(ui.text.isEmpty ? "No log output yet." : ui.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .defaultScrollAnchor(.bottom)
        .toolbar {
            Button("Reveal config", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.config]) }
            Button("Refresh", systemImage: "arrow.clockwise") { ui.text = vpn.logText() }
        }
        .onAppear { ui.text = vpn.logText() }
        .onReceive(timer) { _ in ui.text = vpn.logText() }
    }
}

final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var page: SettingsPage? = .servers
}

private final class ServersUI: ObservableObject {
    @Published var newLink = ""
    @Published var message: String?
}

private final class SplitUI: ObservableObject {
    @Published var draft = SplitTunnelSettings()
    @Published var countries = ""
    @Published var domains = ""
    @Published var ips = ""
    @Published var apps = ""
    @Published var loaded = false
}

private final class LogsUI: ObservableObject {
    @Published var text = ""
}
