import AppKit
import Foundation

@MainActor
final class VPNController: ObservableObject {
    enum Status: Equatable {
        case disconnected, connecting, connected, disconnecting
        case failed(String)
    }

    @Published var settings: AppSettings { didSet { save() } }
    @Published private(set) var status: Status = .disconnected
    @Published private(set) var lastCheck: String?
    @Published private(set) var helperInstalled = false

    private var process: Process?
    private var activeMode: ConnectionMode?
    private var pollTimer: Timer?

    init() {
        if let data = try? Data(contentsOf: Paths.settings),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        } else {
            settings = AppSettings()
        }
        importBundledEnvIfNeeded()
        refreshHelperState()
        // A TUN session survives app restarts (it runs as root); pick it back up.
        if helperInstalled, helper(["status"]).ok {
            activeMode = .tun
            status = .connected
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    var selectedProfile: ServerProfile? {
        settings.profiles.first { $0.id == settings.selectedProfileID } ?? settings.profiles.first
    }

    var isActive: Bool { status == .connected || status == .connecting }

    // MARK: - Profiles

    @discardableResult
    func importLinks(from text: String) -> Int {
        let links = URIParser.links(in: text)
        var added = 0
        for link in links where !settings.profiles.contains(where: { $0.uri == link }) {
            do {
                _ = try URIParser.outbound(from: link, tag: "proxy")
                settings.profiles.append(ServerProfile(uri: link))
                added += 1
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
        if settings.selectedProfileID == nil { settings.selectedProfileID = settings.profiles.first?.id }
        return added
    }

    func removeProfile(_ p: ServerProfile) {
        settings.profiles.removeAll { $0.id == p.id }
        if settings.selectedProfileID == p.id { settings.selectedProfileID = settings.profiles.first?.id }
    }

    private func importBundledEnvIfNeeded() {
        guard !settings.didImportBundledEnv else { return }
        if let url = Bundle.main.url(forResource: "default", withExtension: "env"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            importLinks(from: text)
        }
        settings.didImportBundledEnv = true
    }

    // MARK: - Connect / disconnect

    func toggle() { isActive ? disconnect() : connect() }

    func connect() {
        guard let profile = selectedProfile else { status = .failed("Add a server first"); return }
        status = .connecting
        let mode = settings.mode
        let snapshot = settings
        Task { [weak self] in
            let result = await Task.detached { Self.start(profile: profile, settings: snapshot, mode: mode) }.value
            guard let self else { return }
            switch result {
            case .success(let proc):
                self.process = proc
                self.activeMode = mode
                self.status = .connected
                self.checkConnection()
            case .failure(let err):
                self.status = .failed(err.localizedDescription)
            }
        }
    }

    func disconnect() {
        status = .disconnecting
        let mode = activeMode
        let proc = process
        process = nil
        activeMode = nil
        lastCheck = nil
        Task { [weak self] in
            await Task.detached { Self.stop(mode: mode, process: proc) }.value
            self?.status = .disconnected
        }
    }

    /// Re-apply config after changing split-tunnel rules or the server.
    func reconnectIfActive() {
        guard status == .connected else { return }
        let mode = activeMode
        let proc = process
        process = nil
        status = .connecting
        Task { [weak self] in
            await Task.detached { Self.stop(mode: mode, process: proc) }.value
            self?.connect()
        }
    }

    func shutdown() {
        guard isActive else { return }
        Self.stop(mode: activeMode, process: process)
    }

    private nonisolated static func stop(mode: ConnectionMode?, process: Process?) {
        switch mode {
        case .systemProxy: _ = SystemProxy.disable()
        case .tun: _ = helperStatic(["stop"])
        case nil: break
        }
        process?.terminate()
        process?.waitUntilExit()
    }

    private nonisolated static func start(profile: ServerProfile, settings: AppSettings, mode: ConnectionMode) -> Result<Process?, Error> {
        do {
            guard let xray = Paths.bundledXray else { throw Failure("xray binary missing from app bundle") }

            // Resolve the server name up front: in TUN mode the system resolver points into the tunnel
            // (Xray would need the tunnel to find the tunnel), and a LAN router may answer with a private
            // address that isn't reachable (split-horizon DNS). TLS SNI and the Host header keep the name.
            var ip: String?
            if let host = URIParser.host(of: profile.uri), !Net.isIPAddress(host) {
                ip = Net.resolveServer(host)
                if ip == nil { throw Failure("Cannot resolve \(host)") }
            }
            let config = try XrayConfig.build(profile: profile, settings: settings, resolvedServerIP: ip)
            try XrayConfig.data(config).write(to: Paths.config, options: .atomic)

            let test = Shell.run(xray.path, ["run", "-test", "-c", Paths.config.path])
            if !test.ok { throw Failure("Config rejected by xray:\n" + test.output.suffix(600)) }

            switch mode {
            case .systemProxy:
                let p = Process()
                p.executableURL = xray
                p.arguments = ["run", "-c", Paths.config.path]
                p.environment = ["XRAY_LOCATION_ASSET": Paths.assetsDir?.path ?? ""]
                FileManager.default.createFile(atPath: Paths.proxyLog.path, contents: nil)
                let log = try FileHandle(forWritingTo: Paths.proxyLog)
                p.standardOutput = log
                p.standardError = log
                try p.run()
                Thread.sleep(forTimeInterval: 0.7)
                guard p.isRunning else { throw Failure("xray exited: " + tail(Paths.proxyLog, lines: 5)) }
                guard SystemProxy.enable(httpPort: settings.httpPort, socksPort: settings.socksPort) else {
                    p.terminate()
                    throw Failure("Could not set the system proxy")
                }
                return .success(p)
            case .tun:
                guard FileManager.default.isExecutableFile(atPath: Paths.helperScript) else {
                    throw Failure("Install the TUN helper first (Settings → General)")
                }
                var args = ["start", Paths.config.path]
                if settings.tunPreventDNSLeak { args.append("--dns") }
                let r = helperStatic(args)
                if !r.ok { throw Failure("TUN start failed: \(r.output)\n" + tail(Paths.tunLog, lines: 5)) }
                return .success(nil)
            }
        } catch {
            return .failure(error)
        }
    }

    private func poll() {
        guard status == .connected else { return }
        let alive: Bool
        switch activeMode {
        case .systemProxy: alive = process?.isRunning ?? false
        case .tun: alive = helper(["status"]).ok
        case nil: alive = false
        }
        if !alive {
            if activeMode == .systemProxy { _ = SystemProxy.disable() }
            process = nil
            activeMode = nil
            status = .failed("xray stopped unexpectedly — see Logs")
        }
    }

    // MARK: - Connection check

    func checkConnection() {
        lastCheck = "Checking…"
        let port = settings.socksPort
        Task { [weak self] in
            let text = await Self.trace(socksPort: port)
            self?.lastCheck = text
        }
    }

    private nonisolated static func trace(socksPort: Int) async -> String {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort as String: socksPort,
        ]
        cfg.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: cfg)
        let start = Date()
        do {
            let (data, _) = try await session.data(from: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            var kv: [String: String] = [:]
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { kv[String(parts[0])] = String(parts[1]) }
            }
            return "Exit IP \(kv["ip"] ?? "?") · \(kv["loc"] ?? "?") · \(ms) ms"
        } catch {
            return "Check failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Privileged helper

    func refreshHelperState() {
        helperInstalled = FileManager.default.isExecutableFile(atPath: Paths.helperScript)
            && FileManager.default.fileExists(atPath: "/etc/sudoers.d/vpnbar")
    }

    func installHelper() {
        guard let res = Bundle.main.resourceURL else { return }
        let cmd = "/bin/sh \(Shell.quote(res.appendingPathComponent("install-helper.sh").path)) \(Shell.quote(res.path)) \(Shell.quote(NSUserName()))"
        let r = Shell.runAsAdmin(cmd, prompt: "\(Brand.name) wants to install its TUN helper.")
        if !r.ok { status = .failed("Helper install failed: \(r.output)") }
        refreshHelperState()
    }

    func uninstallHelper() {
        guard let res = Bundle.main.resourceURL else { return }
        if activeMode == .tun { disconnect() }
        let cmd = "/bin/sh \(Shell.quote(res.appendingPathComponent("uninstall-helper.sh").path))"
        _ = Shell.runAsAdmin(cmd, prompt: "\(Brand.name) wants to remove its TUN helper.")
        refreshHelperState()
    }

    private func helper(_ args: [String]) -> Shell.Result { Self.helperStatic(args) }

    private nonisolated static func helperStatic(_ args: [String]) -> Shell.Result {
        Shell.run("/usr/bin/sudo", ["-n", Paths.helperScript] + args)
    }

    // MARK: - Logs

    func logText() -> String {
        let url = (activeMode ?? settings.mode) == .tun ? Paths.tunLog : Paths.proxyLog
        return Self.tail(url, lines: 300)
    }

    nonisolated static func tail(_ url: URL, lines: Int) -> String {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    // MARK: - Persistence & utils

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { try? data.write(to: Paths.settings, options: .atomic) }
    }
}

struct Failure: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
