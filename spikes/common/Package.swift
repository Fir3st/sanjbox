// swift-tools-version: 6.0
import PackageDescription

// Shared probe kit for all Sanjbox spikes (WP0.3). No external dependencies by design:
// probes run inside compartments before any boundary is proven.
let package = Package(
    name: "SanjboxProbeKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SanjboxProbeKit", targets: ["SanjboxProbeKit"]),
        .library(name: "SanjboxNetworkProvenance", targets: ["SanjboxNetworkProvenance"]),
        .executable(name: "sanjbox-whoami", targets: ["sanjbox-whoami"]),
        .executable(name: "sanjbox-canary", targets: ["sanjbox-canary"]),
        .executable(name: "sanjbox-counterpart", targets: ["sanjbox-counterpart"]),
    ],
    targets: [
        .target(name: "SanjboxProbeKit"),
        .target(name: "SanjboxNetworkProvenance", dependencies: ["SanjboxProbeKit"]),
        .testTarget(name: "SanjboxNetworkProvenanceTests", dependencies: ["SanjboxNetworkProvenance"]),
        .executableTarget(name: "sanjbox-whoami", dependencies: ["SanjboxProbeKit"]),
        .executableTarget(name: "sanjbox-canary", dependencies: ["SanjboxProbeKit"]),
        .testTarget(name: "SanjboxProbeKitTests", dependencies: ["SanjboxProbeKit"]),
        // Independent counterpart for network leak tests (WP0.4); shares only the canary and log formats.
        .target(name: "SanjboxCounterpart", dependencies: ["SanjboxProbeKit"]),
        .executableTarget(name: "sanjbox-counterpart", dependencies: ["SanjboxCounterpart", "SanjboxProbeKit", "SanjboxNetworkProvenance"]),
        .testTarget(name: "SanjboxCounterpartTests", dependencies: ["SanjboxCounterpart", "SanjboxProbeKit"]),
    ]
)
