import Foundation

/// One server, stored as the share link exported by 3x-ui (vless://, http://, https://, socks://).
struct ServerProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var uri: String

    init(uri: String, name: String? = nil) {
        self.uri = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name ?? URIParser.displayName(for: self.uri)
    }
}

enum ConnectionMode: String, Codable, CaseIterable, Identifiable {
    /// Local SOCKS/HTTP proxy + macOS system proxy. No admin rights needed.
    case systemProxy
    /// Full-device VPN through an Xray utun interface. Needs the one-time privileged helper.
    case tun

    var id: String { rawValue }
    var title: String {
        switch self {
        case .systemProxy: return "System Proxy"
        case .tun: return "TUN (full VPN)"
        }
    }
}

struct SplitTunnelSettings: Codable, Hashable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        /// Everything goes through the VPN except the listed rules.
        case bypassListed
        /// Only the listed rules go through the VPN; everything else is direct.
        case onlyListed

        var id: String { rawValue }
        var title: String {
            switch self {
            case .bypassListed: return "VPN for everything, except the list"
            case .onlyListed: return "VPN only for the list"
            }
        }
    }

    var enabled = true
    var mode: Mode = .bypassListed
    var bypassLAN = true
    var blockAds = false
    /// Two-letter country codes, e.g. "ru" -> geoip:ru and every *.ru domain.
    var countries: [String] = []
    /// One rule per entry: example.com, *.example.com, geosite:netflix, full:x.y, keyword:foo, regexp:...
    var domains: [String] = []
    /// IP, CIDR or geoip:xx.
    var ips: [String] = []
    /// Application bundle or executable paths. Matched by process (works best in TUN mode).
    var apps: [String] = []
}

struct AppSettings: Codable {
    var profiles: [ServerProfile] = []
    var selectedProfileID: UUID?
    var mode: ConnectionMode = .systemProxy
    var split = SplitTunnelSettings()
    var socksPort = 10808
    var httpPort = 10809
    var tunPreventDNSLeak = true
    var didImportBundledEnv = false
}

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("shmivanvpn", isDirectory: true)
        // Keep servers and split-tunnel rules from before the rename.
        let old = base.appendingPathComponent("VPNBar", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: url)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static var settings: URL { support.appendingPathComponent("settings.json") }
    static var config: URL { support.appendingPathComponent("xray-config.json") }
    static var proxyLog: URL { support.appendingPathComponent("xray.log") }
    static let tunLog = URL(fileURLWithPath: "/var/log/vpnbar-xray.log")

    static let helperDir = "/Library/PrivilegedHelperTools"
    static let helperScript = "\(helperDir)/vpnbar-tun"

    static var bundledXray: URL? { Bundle.main.url(forResource: "xray", withExtension: nil) }
    static var assetsDir: URL? { Bundle.main.resourceURL }
}
