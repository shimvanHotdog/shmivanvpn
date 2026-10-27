import Foundation

enum Net {
    static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    /// System resolver first; if it fails or returns a private/LAN address, ask public resolvers directly.
    static func resolveServer(_ host: String) -> String? {
        if let ip = resolve(host), !isPrivateIPv4(ip) { return ip }
        for server in ["1.1.1.1", "8.8.8.8"] {
            let out = Shell.run("/usr/bin/dig", ["+short", "+time=2", "+tries=1", "@\(server)", host, "A"]).output
            if let ip = out.split(separator: "\n").map(String.init).last(where: isIPAddress), !isPrivateIPv4(ip) {
                return ip
            }
        }
        return resolve(host)
    }

    static func isPrivateIPv4(_ ip: String) -> Bool {
        let o = ip.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4 else { return false }
        return o[0] == 10 || o[0] == 127 || (o[0] == 172 && (16...31).contains(o[1]))
            || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254) || (o[0] == 100 && (64...127).contains(o[1]))
    }

    static func resolve(_ host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        return String(cString: buf)
    }
}
