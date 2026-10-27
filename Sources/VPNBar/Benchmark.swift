import Foundation

/// Runs a full client-side diagnostic against the selected server and produces a plain-text report
/// meant for the server admin. Uses its own temporary Xray instance, so the user's connection and
/// system proxy are left alone. The VLESS UUID is masked in everything the report contains.
@MainActor
final class Benchmark: ObservableObject {
    struct Step: Identifiable {
        enum State { case pending, running, done, failed }
        let id: Int
        let title: String
        var state: State = .pending
        var detail = ""
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var report = ""
    @Published private(set) var isRunning = false

    static let stepTitles = [
        "Environment", "DNS", "Ping", "TCP + TLS handshake", "Direct internet (baseline)",
        "Start tunnel", "Latency through VPN", "Download through VPN", "Upload through VPN",
    ]

    func run(profile: ServerProfile, settings: AppSettings, vpnActive: Bool) {
        guard !isRunning else { return }
        isRunning = true
        report = ""
        steps = Self.stepTitles.enumerated().map { Step(id: $0.offset, title: $0.element) }
        Task { [weak self] in
            let text = await Task.detached {
                var runner = Runner(profile: profile, settings: settings, vpnActive: vpnActive) { index, state, detail in
                    Task { @MainActor in
                        self?.steps[index].state = state
                        self?.steps[index].detail = detail
                    }
                }
                return runner.run()
            }.value
            self?.report = text
            self?.isRunning = false
        }
    }
}

// MARK: - Runner

private struct Runner {
    let profile: ServerProfile
    let settings: AppSettings
    let vpnActive: Bool
    let progress: @Sendable (Int, Benchmark.Step.State, String) -> Void

    private let started = Date()
    private var lines: [String] = []
    private var findings: [String] = []

    init(profile: ServerProfile, settings: AppSettings, vpnActive: Bool,
         progress: @escaping @Sendable (Int, Benchmark.Step.State, String) -> Void) {
        self.profile = profile
        self.settings = settings
        self.vpnActive = vpnActive
        self.progress = progress
    }

    static let downloadBytes = 50_000_000
    static let uploadBytes = 25_000_000
    static let downURL = "https://speed.cloudflare.com/__down?bytes=\(downloadBytes)"
    static let upURL = "https://speed.cloudflare.com/__up"
    static let traceURL = "https://www.cloudflare.com/cdn-cgi/trace"
    static let pingURL = "https://www.gstatic.com/generate_204"

    mutating func run() -> String {
        let link = URLComponents(string: profile.uri)
        let q = Dictionary((link?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let host = URIParser.host(of: profile.uri) ?? "?"
        let port = link?.port ?? 443
        let sni = q["sni"].flatMap { $0.isEmpty ? nil : $0 } ?? host

        // 1. Environment
        progress(0, .running, "")
        let xrayVersion = Paths.bundledXray.map { Shell.run($0.path, ["version"]).output.split(separator: "\n").first.map(String.init) ?? "?" } ?? "missing"
        let iface = Self.field(Shell.run("/sbin/route", ["-n", "get", "default"]).output, "interface") ?? "?"
        let otherVPNs = Shell.run("/usr/sbin/scutil", ["--nc", "list"]).output.split(separator: "\n")
            .filter { $0.contains("(Connected)") }
            .compactMap { $0.split(separator: "\"").dropFirst().first.map(String.init) }
        section("Client")
        kv("Generated", ISO8601DateFormatter().string(from: started))
        kv("App", "\(Brand.name) \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
        kv("Core", xrayVersion)
        kv("macOS", "\(ProcessInfo.processInfo.operatingSystemVersionString), \(Self.arch())")
        kv("Network", "default route via \(iface) (\(Self.interfaceKind(iface)))")
        kv("Other VPNs up", otherVPNs.isEmpty ? "none" : otherVPNs.joined(separator: ", "))
        kv("This app's VPN", vpnActive ? "connected during test (direct baseline may be tunneled)" : "off")
        if !otherVPNs.isEmpty || vpnActive {
            findings.append("A VPN was active on the client during the test; the direct baseline is not a clean measurement.")
        }

        section("Server profile (UUID masked)")
        kv("Remark", profile.name)
        kv("Address", "\(host):\(port)")
        kv("Protocol", "\(link?.scheme ?? "?")  user \(Self.maskedUUID(link?.user))  encryption=\(q["encryption"] ?? "none")  flow=\(q["flow"].flatMap { $0.isEmpty ? nil : $0 } ?? "-")")
        kv("Transport", "\(q["type"] ?? "tcp")  mode=\(q["mode"] ?? "-")  path=\(q["path"] ?? "-")  host=\(q["host"] ?? "-")")
        kv("Security", "\(q["security"] ?? "none")  sni=\(sni)  alpn=\(q["alpn"] ?? "-")  fp=\(q["fp"] ?? "-")")
        progress(0, .done, "\(iface), \(xrayVersion.split(separator: " ").prefix(2).joined(separator: " "))")

        // 2. DNS
        progress(1, .running, "")
        let systemIP = Net.isIPAddress(host) ? host : Net.resolve(host)
        let publicIP = Net.isIPAddress(host) ? host : Self.dig(host, server: "1.1.1.1")
        let dialIP = Net.isIPAddress(host) ? host : Net.resolveServer(host)
        section("DNS")
        kv("System resolver", systemIP ?? "FAILED")
        kv("1.1.1.1", publicIP ?? "FAILED")
        kv("App will dial", dialIP ?? "FAILED")
        if let s = systemIP, let p = publicIP, s != p {
            findings.append("Split-horizon DNS: the client's local resolver returns \(s) but public DNS returns \(p).")
        }
        progress(1, dialIP == nil ? .failed : .done, dialIP ?? "cannot resolve")
        guard let ip = dialIP else { return finish() }

        // 3. Ping
        progress(2, .running, "")
        let ping = Shell.run("/sbin/ping", ["-c", "10", "-i", "0.2", "-t", "8", "-q", ip]).output
        let loss = ping.range(of: #"[\d.]+% packet loss"#, options: .regularExpression).map { String(ping[$0]) } ?? "?"
        let rtt = ping.split(separator: "\n").first { $0.contains("min/avg/max") }.map { String($0.split(separator: "=").last ?? "").trimmingCharacters(in: .whitespaces) } ?? "no reply"
        section("ICMP ping \(ip)")
        kv("Loss", loss)
        kv("RTT min/avg/max/stddev", rtt)
        progress(2, .done, "\(rtt.split(separator: "/").dropFirst().first.map { "\($0) ms avg" } ?? rtt), \(loss)")

        // 4. TCP + TLS to every candidate address
        progress(3, .running, "")
        section("TCP + TLS to \(sni):\(port)")
        var tlsOK = false
        for candidate in Array(NSOrderedSet(array: [ip, systemIP, publicIP].compactMap { $0 })) as! [String] {
            let c = Self.curl(["--resolve", "\(sni):\(port):\(candidate)", "--http2", "https://\(sni):\(port)/"], timeout: 8)
            let cert = Self.certificate(ip: candidate, port: port, sni: sni)
            let label = candidate == ip ? "\(candidate) (dialed)" : candidate
            if c.ok || c.httpCode > 0 {
                kv(label, "tcp \(c.ms("time_connect")) ms, tls \(c.ms("time_appconnect")) ms, HTTP/\(c["http_version"] ?? "?") \(c.httpCode), cert \(cert)")
            } else {
                kv(label, "FAILED: \(c.error)  cert \(cert)")
            }
            // curl verifies the chain and hostname (incl. SANs), so any HTTP status means the certificate is valid for the SNI.
            let certMatches = c.httpCode > 0
            if !certMatches, c.error.lowercased().contains("certificate") || c.error.contains("SSL") {
                findings.append("TLS on \(candidate):\(port) failed for SNI \(sni): \(c.error) (cert \(cert)).")
            }
            if candidate == ip { tlsOK = c.httpCode > 0 && certMatches }
        }
        progress(3, tlsOK ? .done : .failed, tlsOK ? "ok" : "TLS to the server failed or wrong certificate")

        // 5. Direct baseline
        progress(4, .running, "")
        section("Direct internet (no VPN)")
        let directTrace = Self.trace(proxy: nil)
        kv("Public IP / colo", directTrace)
        let directLat = Self.latency(proxy: nil, samples: 5)
        kv("HTTPS latency", directLat.text)
        let directDown = Self.download(proxy: nil, streams: 1)
        kv("Download", directDown.text)
        let directUp = Self.upload(proxy: nil)
        kv("Upload", directUp.text)
        progress(4, .done, "↓ \(directDown.short)  ↑ \(directUp.short)")

        // 6. Temporary tunnel
        progress(5, .running, "")
        guard let tunnel = TempTunnel(profile: profile, dialIP: ip) else {
            progress(5, .failed, "could not start xray")
            findings.append("Xray failed to start with this profile.")
            return finish()
        }
        defer { tunnel.stop() }
        let proxy = "127.0.0.1:\(tunnel.socksPort)"
        let vpnTrace = Self.trace(proxy: proxy)
        let tunnelUp = !vpnTrace.hasPrefix("FAILED")
        section("Through VPN")
        kv("Exit IP / colo", vpnTrace)
        progress(5, tunnelUp ? .done : .failed, vpnTrace)
        if !tunnelUp {
            findings.append("No traffic passes through the tunnel. See the Xray log below.")
            for i in 6...8 { progress(i, .failed, "skipped") }
            appendLog(tunnel)
            return finish()
        }
        if let exitIP = Self.field(vpnTrace, "ip", separator: "="), directTrace.contains(exitIP) {
            findings.append("Exit IP equals the client's direct IP: the client is behind the same public IP as the server (testing from inside the host network), so speeds are not representative.")
        }

        // 7. Latency
        progress(6, .running, "")
        let vpnLat = Self.latency(proxy: proxy, samples: 10)
        kv("HTTPS latency", vpnLat.text)
        progress(6, .done, vpnLat.short)

        // 8. Download
        progress(7, .running, "1 stream")
        let down1 = Self.download(proxy: proxy, streams: 1)
        kv("Download 1 stream", down1.text)
        progress(7, .running, "4 streams")
        let down4 = Self.download(proxy: proxy, streams: 4)
        kv("Download 4 streams", down4.text)
        progress(7, .done, "\(down1.short) / ×4 \(down4.short)")

        // 9. Upload
        progress(8, .running, "")
        let up = Self.upload(proxy: proxy)
        kv("Upload", up.text)
        progress(8, .done, up.short)

        if directDown.mbps > 0, down1.mbps > 0 {
            let pct = Int(down1.mbps / directDown.mbps * 100)
            kv("VPN vs direct", "download \(pct)%, upload \(directUp.mbps > 0 ? Int(up.mbps / directUp.mbps * 100) : 0)%")
            if down4.mbps > down1.mbps * 1.6 {
                findings.append("4 parallel streams are much faster than 1 (\(down4.short) vs \(down1.short)): per-connection limit, likely TCP congestion control/buffers on the server or the path (BBR helps).")
            }
            if pct < 50 { findings.append("VPN download is \(pct)% of the direct baseline.") }
        }
        if directUp.mbps > 0, up.mbps > 0, up.mbps / directUp.mbps < 0.5 {
            let upPct = Int(up.mbps / directUp.mbps * 100)
            findings.append("VPN upload is only \(upPct)% of direct (\(up.short) vs \(directUp.short)) while download is fine. With XHTTP (mode=\(q["mode"] ?? "auto")) the upload is a long HTTP request body, so this usually points at whatever sits in front of Xray buffering or flow-controlling request bodies (nginx: proxy_request_buffering off, client_max_body_size 0, larger http2 windows; Caddy/Traefik: disable request buffering), or at the inbound's xhttp settings (scMaxBufferedPosts / scMaxEachPostBytes for packet-up).")
        }
        if vpnLat.median > 0, directLat.median > 0, vpnLat.median > directLat.median * 3 {
            findings.append("VPN latency (\(vpnLat.median) ms) is more than 3× direct (\(directLat.median) ms).")
        }
        appendLog(tunnel)
        return finish()
    }

    // MARK: Report assembly

    private mutating func section(_ title: String) { lines.append("\n== \(title) ==") }
    private mutating func kv(_ k: String, _ v: String) { lines.append("\(k.padding(toLength: max(k.count, 22), withPad: " ", startingAt: 0)) \(v)") }

    private mutating func appendLog(_ tunnel: TempTunnel) {
        let log = tunnel.logLines()
            .filter { ($0.contains("[Warning]") || $0.contains("[Error]") || $0.contains("failed")) && !$0.contains("core: Xray") }
        section("Xray warnings/errors during test (\(log.count))")
        lines.append(contentsOf: log.suffix(25).map { Self.redact($0, uuid: URLComponents(string: profile.uri)?.user) })
        if log.isEmpty { lines.append("none") }
    }

    private func finish() -> String {
        var out = "\(Brand.name) connection report"
        out += "\nDuration \(Int(Date().timeIntervalSince(started))) s. Speed tests use speed.cloudflare.com (\(Self.downloadBytes / 1_000_000) MB down, \(Self.uploadBytes / 1_000_000) MB up)."
        out += "\n\n== Findings =="
        out += findings.isEmpty ? "\nNo obvious problems detected." : findings.map { "\n- \($0)" }.joined()
        out += "\n" + lines.joined(separator: "\n")
        return Self.redact(out, uuid: URLComponents(string: profile.uri)?.user) + "\n"
    }

    // MARK: Measurements

    struct Rate {
        var mbps: Double
        var text: String
        var short: String { mbps > 0 ? String(format: "%.0f Mbit/s", mbps) : "failed" }
    }

    struct Latency {
        var median: Int
        var text: String
        var short: String { median > 0 ? "\(median) ms" : "failed" }
    }

    static func trace(proxy: String?) -> String {
        let r = Shell.run("/usr/bin/curl", ["-sS", "-m", "12"] + proxyArgs(proxy) + [traceURL])
        guard r.ok else { return "FAILED: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))" }
        let kv = Dictionary(r.output.split(separator: "\n").compactMap { line -> (String, String)? in
            let p = line.split(separator: "=", maxSplits: 1)
            return p.count == 2 ? (String(p[0]), String(p[1])) : nil
        }, uniquingKeysWith: { a, _ in a })
        return "ip=\(kv["ip"] ?? "?")  loc=\(kv["loc"] ?? "?")  colo=\(kv["colo"] ?? "?")  http=\(kv["http"] ?? "?")"
    }

    static func latency(proxy: String?, samples: Int) -> Latency {
        var times: [Int] = []
        var failures = 0
        for _ in 0..<samples {
            let c = curl(proxyArgs(proxy) + [pingURL], timeout: 8)
            if c.httpCode == 204, let t = Double(c["time_total"] ?? "") { times.append(Int(t * 1000)) } else { failures += 1 }
        }
        guard !times.isEmpty else { return Latency(median: 0, text: "all \(samples) requests failed") }
        let sorted = times.sorted()
        let med = sorted[sorted.count / 2]
        let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        return Latency(median: med, text: "first \(times[0]) ms, median \(med) ms, p90 \(p90) ms, min \(sorted[0]) ms, failed \(failures)/\(samples)")
    }

    static func download(proxy: String?, streams: Int) -> Rate {
        let results = parallel(streams) { _ in curl(proxyArgs(proxy) + [downURL], timeout: 30) }
        let bytes = results.compactMap { Double($0["size_download"] ?? "") }.reduce(0, +)
        let secs = results.compactMap { Double($0["time_total"] ?? "") }.max() ?? 0
        let errors = results.filter { !$0.ok }.map(\.error)
        guard bytes > 0, secs > 0 else { return Rate(mbps: 0, text: "FAILED: \(errors.first ?? "no data")") }
        let mbps = bytes * 8 / secs / 1_000_000
        let ttfb = results.compactMap { Double($0["time_starttransfer"] ?? "") }.min().map { Int($0 * 1000) } ?? 0
        var text = String(format: "%.1f Mbit/s  (%.1f MB in %.1f s, ttfb %d ms)", mbps, bytes / 1_000_000, secs, ttfb)
        if !errors.isEmpty { text += "  [\(errors.count) stream(s) ended early: \(errors[0])]" }
        return Rate(mbps: mbps, text: text)
    }

    static func upload(proxy: String?) -> Rate {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("shmivanvpn-upload.bin")
        if (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) != uploadBytes {
            var data = Data(count: uploadBytes)
            data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, uploadBytes, $0.baseAddress!) }
            try? data.write(to: file)
        }
        let c = curl(proxyArgs(proxy) + ["--data-binary", "@\(file.path)", "-H", "Content-Type: application/octet-stream", upURL], timeout: 30)
        guard let bytes = Double(c["size_upload"] ?? ""), let secs = Double(c["time_total"] ?? ""), bytes > 0, secs > 0 else {
            return Rate(mbps: 0, text: "FAILED: \(c.error)")
        }
        let mbps = bytes * 8 / secs / 1_000_000
        var text = String(format: "%.1f Mbit/s  (%.1f MB in %.1f s)", mbps, bytes / 1_000_000, secs)
        if !c.ok { text += "  [ended early: \(c.error)]" }
        return Rate(mbps: mbps, text: text)
    }

    // MARK: Tools

    struct Curl {
        var status: Int32
        var fields: [String: String]
        var error: String
        var ok: Bool { status == 0 }
        var httpCode: Int { Int(fields["http_code"] ?? "") ?? 0 }
        subscript(_ k: String) -> String? { fields[k] }
        func ms(_ k: String) -> Int { Int((Double(fields[k] ?? "") ?? 0) * 1000) }
    }

    static let curlFields = ["http_code", "http_version", "time_connect", "time_appconnect", "time_starttransfer",
                             "time_total", "size_download", "size_upload", "remote_ip"]

    static func curl(_ args: [String], timeout: Int) -> Curl {
        let format = curlFields.map { "\($0)=%{\($0)}" }.joined(separator: "\\n")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-sS", "-o", "/dev/null", "-m", "\(timeout)", "-w", format] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return Curl(status: -1, fields: [:], error: error.localizedDescription) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var fields: [String: String] = [:]
        for line in String(decoding: o, as: UTF8.self).split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        return Curl(status: p.terminationStatus, fields: fields,
                    error: String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func proxyArgs(_ proxy: String?) -> [String] {
        proxy.map { ["--socks5-hostname", $0] } ?? ["--noproxy", "*"]
    }

    static func parallel<T>(_ n: Int, _ body: @escaping @Sendable (Int) -> T) -> [T] {
        let lock = NSLock()
        var results: [T] = []
        DispatchQueue.concurrentPerform(iterations: n) { i in
            let r = body(i)
            lock.lock(); results.append(r); lock.unlock()
        }
        return results
    }

    static func certificate(ip: String, port: Int, sni: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = ["s_client", "-connect", "\(ip):\(port)", "-servername", sni]
        let out = Pipe()
        p.standardInput = Pipe()  // closed stdin -> s_client exits after the handshake
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return "none (openssl missing)" }
        let deadline = Date().addingTimeInterval(8)
        DispatchQueue.global().async { while p.isRunning, Date() < deadline { usleep(100_000) }; if p.isRunning { p.terminate() } }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("subject=") }) else { return "none (no handshake)" }
        let issuer = text.split(separator: "\n").first { $0.hasPrefix("issuer=") }.map { $0.components(separatedBy: "CN=").last ?? "" } ?? "?"
        return "\(line.replacingOccurrences(of: "subject=", with: "")) (issuer \(issuer))"
    }

    static func dig(_ host: String, server: String) -> String? {
        Shell.run("/usr/bin/dig", ["+short", "+time=2", "+tries=1", "@\(server)", host, "A"]).output
            .split(separator: "\n").map(String.init).last(where: Net.isIPAddress)
    }

    static func field(_ text: String, _ key: String, separator: Character = ":") -> String? {
        for part in text.split(whereSeparator: { $0 == "\n" || $0 == " " && separator == "=" }) {
            let kv = part.split(separator: separator, maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == key { return kv[1].trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    static func interfaceKind(_ iface: String) -> String {
        if iface.hasPrefix("utun") { return "VPN tunnel" }
        let hw = Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"]).output.components(separatedBy: "\n\n")
        return hw.first { $0.contains("Device: \(iface)") }?.split(separator: "\n").first?
            .replacingOccurrences(of: "Hardware Port: ", with: "") ?? "unknown"
    }

    static func arch() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }

    static func maskedUUID(_ id: String?) -> String {
        guard let id, id.count > 4 else { return "-" }
        return "…" + id.suffix(4)
    }

    static func redact(_ text: String, uuid: String?) -> String {
        guard let uuid, !uuid.isEmpty else { return text }
        return text.replacingOccurrences(of: uuid, with: maskedUUID(uuid))
    }
}

// MARK: - Temporary Xray instance

private final class TempTunnel {
    let socksPort: Int
    private let process = Process()
    private let log: URL
    private let config: URL

    init?(profile: ServerProfile, dialIP: String) {
        guard let xray = Paths.bundledXray, let port = Self.freePort(), let httpPort = Self.freePort() else { return nil }
        socksPort = port
        log = FileManager.default.temporaryDirectory.appendingPathComponent("shmivanvpn-bench.log")
        config = Paths.support.appendingPathComponent("bench-config.json")

        var s = AppSettings()
        s.mode = .systemProxy
        s.split.enabled = false
        s.socksPort = port
        s.httpPort = httpPort
        guard var cfg = try? XrayConfig.build(profile: profile, settings: s, resolvedServerIP: dialIP) else { return nil }
        cfg["log"] = ["loglevel": "info"]
        guard (try? XrayConfig.data(cfg).write(to: config, options: .atomic)) != nil else { return nil }

        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else { return nil }
        process.executableURL = xray
        process.arguments = ["run", "-c", config.path]
        process.standardOutput = handle
        process.standardError = handle
        guard (try? process.run()) != nil else { return nil }
        // Wait until the SOCKS port accepts connections.
        for _ in 0..<30 where process.isRunning {
            if Shell.run("/usr/bin/nc", ["-z", "-G", "1", "127.0.0.1", "\(port)"]).ok { return }
            usleep(100_000)
        }
        if !process.isRunning { return nil }
    }

    func logLines() -> [String] {
        (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    }

    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: config)
    }

    static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                               sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        return ok ? Int(UInt16(bigEndian: addr.sin_port)) : nil
    }
}
