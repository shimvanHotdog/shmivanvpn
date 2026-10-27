import Foundation

enum Shell {
    struct Result {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
    }

    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return Result(status: -1, output: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// Runs a shell command as root through the standard macOS administrator password dialog.
    static func runAsAdmin(_ command: String, prompt: String) -> Result {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", script])
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Turns the macOS system HTTP/HTTPS/SOCKS proxy on or off for every active network service.
enum SystemProxy {
    static func services() -> [String] {
        Shell.run("/usr/sbin/networksetup", ["-listallnetworkservices"]).output
            .split(separator: "\n").dropFirst().map(String.init).filter { !$0.hasPrefix("*") }
    }

    static func enable(httpPort: Int, socksPort: Int) -> Bool {
        apply(services().flatMap { svc in [
            ["-setwebproxy", svc, "127.0.0.1", "\(httpPort)"],
            ["-setsecurewebproxy", svc, "127.0.0.1", "\(httpPort)"],
            ["-setsocksfirewallproxy", svc, "127.0.0.1", "\(socksPort)"],
            ["-setproxybypassdomains", svc, "localhost", "127.0.0.1", "*.local", "169.254/16", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"],
        ] })
    }

    static func disable() -> Bool {
        apply(services().flatMap { svc in [
            ["-setwebproxystate", svc, "off"],
            ["-setsecurewebproxystate", svc, "off"],
            ["-setsocksfirewallproxystate", svc, "off"],
        ] })
    }

    /// networksetup works without sudo for admin users on most setups; fall back to one password prompt.
    private static func apply(_ commands: [[String]]) -> Bool {
        var failed = false
        for c in commands {
            let r = Shell.run("/usr/sbin/networksetup", c)
            if !r.ok || r.output.lowercased().contains("admin") { failed = true; break }
        }
        guard failed else { return true }
        let script = commands.map { (["/usr/sbin/networksetup"] + $0).map(Shell.quote).joined(separator: " ") }
            .joined(separator: " && ")
        return Shell.runAsAdmin(script, prompt: "\(Brand.name) needs to change the system proxy.").ok
    }
}
