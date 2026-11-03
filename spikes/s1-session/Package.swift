// swift-tools-version: 6.0
import PackageDescription

// S1 spike (WP1.A1): probe run inside a compartment's invisible session, and a loopback
// forwarder that lets Screen Sharing.app reach this Mac's own VNC server.
let package = Package(
    name: "SanjboxS1",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../common")],
    targets: [
        .target(name: "S1Probe", dependencies: [.product(name: "SanjboxProbeKit", package: "common")]),
        .target(name: "S1Forward"),
        .executableTarget(
            name: "sanjbox-s1-probe",
            dependencies: ["S1Probe", .product(name: "SanjboxProbeKit", package: "common")]
        ),
        .executableTarget(
            name: "sanjbox-s1-forward",
            dependencies: ["S1Forward", .product(name: "SanjboxProbeKit", package: "common")]
        ),
        .testTarget(name: "S1ProbeTests", dependencies: ["S1Probe", "S1Forward"]),
    ]
)
