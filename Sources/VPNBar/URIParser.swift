import Foundation

enum URIError: LocalizedError {
    case unsupported(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let s): return "Unsupported link type: \(s)"
        case .invalid(let s): return "Invalid link: \(s)"
        }
    }
}

/// Turns 3x-ui / v2rayN style share links into Xray outbound objects.
enum URIParser {
    static let supportedSchemes = ["vless", "http", "https", "socks", "socks5"]

    /// Extracts every supported link from free text (a .env file, clipboard, …).
    static func links(in text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { line in
            var line = line.trimmingCharacters(in: .whitespaces)
            // Accept `KEY=vless://...` and quoted values from .env files.
            if let eq = line.firstIndex(of: "="), !line[..<eq].contains(":") {
                line = String(line[line.index(after: eq)...])
            }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            guard let scheme = line.split(separator: ":").first?.lowercased(),
                  supportedSchemes.contains(scheme), line.contains("://") else { return nil }
            return line
        }
    }

    static func displayName(for uri: String) -> String {
        guard let c = URLComponents(string: uri) else { return "Server" }
        if let f = c.fragment, !f.isEmpty { return f.removingPercentEncoding ?? f }
        return c.host ?? "Server"
    }

    static func host(of uri: String) -> String? {
        URLComponents(string: uri)?.host.map(stripBrackets)
    }

    /// - Parameter resolvedAddress: when set, the outbound dials this IP while TLS/Host keep the original name.
    static func outbound(from uri: String, tag: String, resolvedAddress: String? = nil) throws -> [String: Any] {
        guard let c = URLComponents(string: uri), let scheme = c.scheme?.lowercased() else {
            throw URIError.invalid("cannot parse")
        }
        switch scheme {
        case "vless": return try vless(c, tag: tag, resolvedAddress: resolvedAddress)
        case "http", "https", "socks", "socks5": return try plainProxy(c, scheme: scheme, tag: tag, resolvedAddress: resolvedAddress)
        default: throw URIError.unsupported(scheme)
        }
    }

    // MARK: - VLESS

    private static func vless(_ c: URLComponents, tag: String, resolvedAddress: String?) throws -> [String: Any] {
        guard let id = c.user?.removingPercentEncoding, !id.isEmpty else { throw URIError.invalid("missing UUID") }
        guard let rawHost = c.host, !rawHost.isEmpty else { throw URIError.invalid("missing host") }
        let host = stripBrackets(rawHost)
        let port = c.port ?? 443
        let q = query(c)

        var user: [String: Any] = ["id": id, "encryption": q["encryption"] ?? "none"]
        if let flow = q["flow"], !flow.isEmpty { user["flow"] = flow }

        let server: [String: Any] = ["address": resolvedAddress ?? host, "port": port, "users": [user]]
        return [
            "tag": tag,
            "protocol": "vless",
            "settings": ["vnext": [server]],
            "streamSettings": try streamSettings(q, originalHost: host),
        ]
    }

    private static func streamSettings(_ q: [String: String], originalHost: String) throws -> [String: Any] {
        var network = (q["type"] ?? "tcp").lowercased()
        if network == "splithttp" { network = "xhttp" }
        if network == "raw" { network = "tcp" }
        let security = (q["security"] ?? "none").lowercased()
        let hostHeader = q["host"].flatMap { $0.isEmpty ? nil : $0 }
        let path = q["path"].flatMap { $0.isEmpty ? nil : $0 } ?? "/"

        var s: [String: Any] = ["network": network, "security": security]

        switch network {
        case "tcp":
            if q["headerType"] == "http" {
                s["tcpSettings"] = ["header": [
                    "type": "http",
                    "request": ["path": [path], "headers": ["Host": [hostHeader ?? originalHost]]],
                ]]
            }
        case "ws":
            s["wsSettings"] = ["path": path, "host": hostHeader ?? originalHost]
        case "httpupgrade":
            s["httpupgradeSettings"] = ["path": path, "host": hostHeader ?? originalHost]
        case "grpc":
            var g: [String: Any] = ["serviceName": q["serviceName"] ?? ""]
            if let a = q["authority"], !a.isEmpty { g["authority"] = a }
            if q["mode"] == "multi" { g["multiMode"] = true }
            s["grpcSettings"] = g
        case "xhttp":
            var x: [String: Any] = ["path": path, "mode": q["mode"] ?? "auto", "host": hostHeader ?? originalHost]
            if let extra = q["extra"], let data = extra.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                x["extra"] = obj
            }
            s["xhttpSettings"] = x
        default:
            throw URIError.unsupported("transport \(network)")
        }

        let sni = q["sni"].flatMap { $0.isEmpty ? nil : $0 } ?? hostHeader ?? originalHost
        let fp = q["fp"].flatMap { $0.isEmpty ? nil : $0 }
        switch security {
        case "tls":
            var t: [String: Any] = ["serverName": sni]
            if let fp { t["fingerprint"] = fp }
            if let alpn = q["alpn"], !alpn.isEmpty { t["alpn"] = alpn.split(separator: ",").map(String.init) }
            if q["allowInsecure"] == "1" || q["insecure"] == "1" { t["allowInsecure"] = true }
            s["tlsSettings"] = t
        case "reality":
            guard let pbk = q["pbk"], !pbk.isEmpty else { throw URIError.invalid("reality link without pbk") }
            var r: [String: Any] = ["serverName": sni, "fingerprint": fp ?? "chrome", "publicKey": pbk]
            if let sid = q["sid"] { r["shortId"] = sid }
            if let spx = q["spx"] { r["spiderX"] = spx }
            if let pqv = q["pqv"], !pqv.isEmpty { r["mldsa65Verify"] = pqv }
            s["realitySettings"] = r
        case "none":
            break
        default:
            throw URIError.unsupported("security \(security)")
        }
        return s
    }

    // MARK: - HTTP / SOCKS upstream proxies

    private static func plainProxy(_ c: URLComponents, scheme: String, tag: String, resolvedAddress: String?) throws -> [String: Any] {
        guard let rawHost = c.host, !rawHost.isEmpty else { throw URIError.invalid("missing host") }
        let host = stripBrackets(rawHost)
        let isSocks = scheme.hasPrefix("socks")
        let port = c.port ?? (scheme == "https" ? 443 : isSocks ? 1080 : 8080)

        var server: [String: Any] = ["address": resolvedAddress ?? host, "port": port]
        if let u = c.user?.removingPercentEncoding, !u.isEmpty {
            server["users"] = [["user": u, "pass": c.password?.removingPercentEncoding ?? ""]]
        }
        var out: [String: Any] = [
            "tag": tag,
            "protocol": isSocks ? "socks" : "http",
            "settings": ["servers": [server]],
        ]
        if scheme == "https" {
            out["streamSettings"] = ["security": "tls", "tlsSettings": ["serverName": host]]
        }
        return out
    }

    // MARK: - Helpers

    private static func query(_ c: URLComponents) -> [String: String] {
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] {
            q[item.name] = item.value ?? ""  // already percent-decoded by URLComponents
        }
        return q
    }

    private static func stripBrackets(_ h: String) -> String {
        h.hasPrefix("[") && h.hasSuffix("]") ? String(h.dropFirst().dropLast()) : h
    }
}
