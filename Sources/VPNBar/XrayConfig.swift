import Foundation

/// Builds a complete Xray JSON config from a profile + split-tunnel settings.
enum XrayConfig {
    static let tunName = "utun99"
    /// Public resolver the system is pointed at in TUN mode; its port 53 is hijacked into Xray's DNS.
    static let tunSystemDNS = "1.1.1.1"

    static func build(profile: ServerProfile, settings: AppSettings, resolvedServerIP: String? = nil) throws -> [String: Any] {
        let isTun = settings.mode == .tun
        let proxy = try URIParser.outbound(from: profile.uri, tag: "proxy", resolvedAddress: resolvedServerIP)

        let sniffing: [String: Any] = ["enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true]
        var inbounds: [[String: Any]] = [
            [
                "tag": "socks-in", "protocol": "socks", "listen": "127.0.0.1", "port": settings.socksPort,
                "settings": ["udp": true], "sniffing": sniffing,
            ],
            [
                "tag": "http-in", "protocol": "http", "listen": "127.0.0.1", "port": settings.httpPort,
                "sniffing": sniffing,
            ],
        ]
        if isTun {
            inbounds.append([
                "tag": "tun-in", "protocol": "tun", "port": 0,
                "settings": [
                    "name": tunName,
                    "mtu": 1500,
                    // Two halves instead of a default route, so the physical default route stays intact.
                    "autoSystemRoutingTable": ["0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"],
                ],
                "sniffing": sniffing,
            ])
        }

        let outbounds: [[String: Any]] = [
            proxy,
            ["tag": "direct", "protocol": "freedom", "streamSettings": ["sockopt": ["domainStrategy": "UseIP"]]],
            ["tag": "block", "protocol": "blackhole"],
            ["tag": "dns-out", "protocol": "dns"],
        ]

        return [
            "log": ["loglevel": "warning"],
            "dns": [
                "tag": "dns-internal",
                "servers": ["1.1.1.1", "8.8.8.8"],
                "queryStrategy": "UseIPv4",
            ],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": ["domainStrategy": "IPIfNonMatch", "rules": routingRules(settings: settings, isTun: isTun)],
        ]
    }

    static func routingRules(settings: AppSettings, isTun: Bool) -> [[String: Any]] {
        let split = settings.split
        var rules: [[String: Any]] = []

        if isTun {
            rules.append(["inboundTag": ["tun-in"], "port": "53", "network": "udp", "outboundTag": "dns-out"])
        }
        // Xray's own DNS lookups always go through the tunnel (no leaks, no poisoned answers).
        rules.append(["inboundTag": ["dns-internal"], "outboundTag": "proxy"])

        guard split.enabled else {
            rules.append(["network": "tcp,udp", "outboundTag": "proxy"])
            return rules
        }

        if split.blockAds { rules.append(["domain": ["geosite:category-ads-all"], "outboundTag": "block"]) }
        if split.bypassLAN {
            rules.append(["ip": ["geoip:private"], "outboundTag": "direct"])
            rules.append(["domain": ["geosite:private"], "outboundTag": "direct"])
        }

        let listed = split.mode == .bypassListed ? "direct" : "proxy"
        let other = split.mode == .bypassListed ? "proxy" : "direct"

        let (domains, ips) = normalizedLists(split)
        let apps = split.apps.map(normalizeApp).filter { !$0.isEmpty }
        if !apps.isEmpty { rules.append(["process": apps, "outboundTag": listed]) }
        if !domains.isEmpty { rules.append(["domain": domains, "outboundTag": listed]) }
        if !ips.isEmpty { rules.append(["ip": ips, "outboundTag": listed]) }

        rules.append(["network": "tcp,udp", "outboundTag": other])
        return rules
    }

    static func normalizedLists(_ split: SplitTunnelSettings) -> (domains: [String], ips: [String]) {
        var domains = split.domains.compactMap(normalizeDomain)
        var ips = split.ips.compactMap(normalizeIP)
        for cc in split.countries.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() })
        where cc.count == 2 && cc.allSatisfy(\.isLetter) {
            domains.append("domain:\(cc)")  // every *.cc domain
            ips.append("geoip:\(cc)")
        }
        return (Array(NSOrderedSet(array: domains)) as! [String], Array(NSOrderedSet(array: ips)) as! [String])
    }

    static func normalizeDomain(_ raw: String) -> String? {
        var d = raw.trimmingCharacters(in: .whitespaces)
        if d.isEmpty || d.hasPrefix("#") { return nil }
        let prefixes = ["geosite:", "domain:", "full:", "keyword:", "regexp:", "ext:"]
        if prefixes.contains(where: { d.lowercased().hasPrefix($0) }) { return d }
        if let url = URL(string: d), let host = url.host, d.contains("://") { d = host }
        while d.hasPrefix("*.") || d.hasPrefix(".") { d.removeFirst(d.hasPrefix("*.") ? 2 : 1) }
        return d.isEmpty ? nil : "domain:\(d.lowercased())"
    }

    static func normalizeIP(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        return s.isEmpty || s.hasPrefix("#") ? nil : s
    }

    /// `/Applications/Telegram.app` -> `/Applications/Telegram.app/` (folder match = every process in the bundle).
    static func normalizeApp(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        return s.hasSuffix(".app") ? s + "/" : s
    }

    static func data(_ config: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
