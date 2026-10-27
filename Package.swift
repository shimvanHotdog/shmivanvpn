// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "VPNBar",
    platforms: [.macOS(.v26)],  // Liquid Glass APIs
    targets: [
        .executableTarget(
            name: "VPNBar",
            path: "Sources/VPNBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
