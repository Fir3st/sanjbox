// swift-tools-version: 6.0
import PackageDescription

// Shared probe kit for all Sanjbox spikes (WP0.3). No external dependencies by design:
// probes run inside compartments before any boundary is proven.
let package = Package(
    name: "SanjboxProbeKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SanjboxProbeKit", targets: ["SanjboxProbeKit"]),
        .executable(name: "sanjbox-whoami", targets: ["sanjbox-whoami"]),
        .executable(name: "sanjbox-canary", targets: ["sanjbox-canary"]),
    ],
    targets: [
        .target(name: "SanjboxProbeKit"),
        .executableTarget(name: "sanjbox-whoami", dependencies: ["SanjboxProbeKit"]),
        .executableTarget(name: "sanjbox-canary", dependencies: ["SanjboxProbeKit"]),
        .testTarget(name: "SanjboxProbeKitTests", dependencies: ["SanjboxProbeKit"]),
    ]
)
