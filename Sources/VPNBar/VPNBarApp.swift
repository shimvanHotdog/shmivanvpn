import AppKit
import Combine
import SwiftUI

enum Brand {
    static let name = "shmivanvpn"
}

@main
struct ShmivanVPNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if let assets = Paths.assetsDir?.path { setenv("XRAY_LOCATION_ASSET", assets, 1) }
        CLI.runIfRequested()
    }

    // The menu bar item and its popover are AppKit (see AppDelegate); SwiftUI needs at least one scene.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Owns the status item. Uses NSPopover rather than MenuBarExtra so the panel grows out of the
/// icon with an arrow pointing at it, instead of floating as a detached window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var vpn: VPNController!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private let benchmark = Benchmark()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        vpn = VPNController()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        let host = NSHostingController(rootView: MenuView(
            openSettings: { [weak self] in self?.showSettings() },
            openBenchmark: { [weak self] in self?.showSettings(page: .benchmark) }
        ).environmentObject(vpn))
        host.sizingOptions = .preferredContentSize  // popover follows the SwiftUI content size
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        vpn.$status.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
        updateIcon()

        CLI.selfTestIfRequested(vpn)
        CLI.benchmarkIfRequested(vpn)
    }

    func applicationWillTerminate(_ notification: Notification) {
        vpn?.shutdown()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            button.highlight(true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }

    private func updateIcon() {
        statusItem.button?.image = Self.statusImage(for: vpn.status) ?? {
            let image = NSImage(systemSymbolName: vpn.menuBarSymbol, accessibilityDescription: Brand.name)
            image?.isTemplate = true
            return image
        }()
        statusItem.button?.toolTip = Brand.name
    }

    private static let face = Bundle.main.url(forResource: "menubar-face", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    /// Round face avatar with a status dot; greyed out while disconnected.
    private static func statusImage(for status: VPNController.Status) -> NSImage? {
        guard let face else { return nil }
        let dot: NSColor? = switch status {
        case .connected: .systemGreen
        case .connecting, .disconnecting: .systemOrange
        case .failed: .systemRed
        case .disconnected: nil
        }
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            let circle = rect.insetBy(dx: 1, dy: 1)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: circle).addClip()
            face.draw(in: circle, from: .zero, operation: .sourceOver, fraction: dot == nil ? 0.55 : 1)
            NSGraphicsContext.restoreGraphicsState()
            if let dot {
                let d = NSRect(x: rect.maxX - 8, y: rect.minY, width: 8, height: 8)
                NSGraphicsContext.current?.compositingOperation = .clear  // cut a ring so the dot stands out
                NSBezierPath(ovalIn: d.insetBy(dx: -1.2, dy: -1.2)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                dot.setFill()
                NSBezierPath(ovalIn: d).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = Brand.name
        return image
    }

    private func showSettings(page: SettingsPage? = nil) {
        popover.performClose(nil)
        if let page { SettingsNav.shared.page = page }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(vpn).environmentObject(benchmark))
            host.sceneBridgingOptions = [.toolbars, .title]  // let SwiftUI drive the titlebar/toolbar
            let window = NSWindow(contentViewController: host)
            window.title = "\(Brand.name) Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 820, height: 600))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

extension VPNController {
    var menuBarSymbol: String {
        switch status {
        case .connected: return "shield.lefthalf.filled"
        case .connecting, .disconnecting: return "shield.lefthalf.filled.trianglebadge.exclamationmark"
        case .failed: return "exclamationmark.shield"
        case .disconnected: return "shield.slash"
        }
    }
}

/// `shmivanvpn --print-config <file-with-link> [tun]` prints the generated Xray config (used by the build script's self-test).
enum CLI {
    /// `shmivanvpn --self-test`: connects with the saved settings, checks the exit IP, disconnects and exits.
    @MainActor static func selfTestIfRequested(_ vpn: VPNController) {
        guard CommandLine.arguments.contains("--self-test") else { return }
        Task { @MainActor in
            func log(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
            vpn.connect()
            while vpn.status == .connecting { try? await Task.sleep(for: .milliseconds(200)) }
            log("status: \(vpn.status)")
            log("system proxy: " + Shell.run("/usr/sbin/scutil", ["--proxy"]).output
                .split(separator: "\n").filter { $0.contains("Enable") || $0.contains("Port") }.joined(separator: ","))
            while vpn.lastCheck == nil || vpn.lastCheck == "Checking…" { try? await Task.sleep(for: .milliseconds(200)) }
            log("check: \(vpn.lastCheck ?? "")")
            let ok = vpn.status == .connected && vpn.lastCheck?.hasPrefix("Exit IP") == true
            vpn.disconnect()
            while vpn.status != .disconnected { try? await Task.sleep(for: .milliseconds(200)) }
            log("after disconnect: " + Shell.run("/usr/sbin/scutil", ["--proxy"]).output
                .split(separator: "\n").filter { $0.contains("Enable") }.joined(separator: ","))
            exit(ok ? 0 : 1)
        }
    }

    /// `shmivanvpn --benchmark`: runs the admin report for the selected server and prints it.
    @MainActor static func benchmarkIfRequested(_ vpn: VPNController) {
        guard CommandLine.arguments.contains("--benchmark") else { return }
        guard let profile = vpn.selectedProfile else { print("no server configured"); exit(1) }
        let bench = Benchmark()
        bench.run(profile: profile, settings: vpn.settings, vpnActive: vpn.isActive)
        Task { @MainActor in
            while bench.isRunning { try? await Task.sleep(for: .milliseconds(300)) }
            FileHandle.standardOutput.write(Data(bench.report.utf8))
            exit(0)
        }
    }

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--print-config"), i + 1 < args.count else { return }
        do {
            let text = try String(contentsOfFile: args[i + 1], encoding: .utf8)
            guard let link = URIParser.links(in: text).first else { throw Failure("no supported link found") }
            var s = AppSettings()
            if args.contains("tun") { s.mode = .tun }
            s.split.countries = ["ru"]
            s.split.domains = ["*.example.org", "geosite:apple"]
            s.split.apps = ["/Applications/Safari.app"]
            let data = try XrayConfig.data(XrayConfig.build(profile: ServerProfile(uri: link), settings: s))
            FileHandle.standardOutput.write(data)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
