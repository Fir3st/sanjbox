// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SanjboxHostAudit",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "sanjbox-host-audit", targets: ["sanjbox-host-audit"]),
               .executable(name: "sanjbox-host-harden", targets: ["sanjbox-host-harden"])],
    dependencies: [.package(path: "../common")],
    targets: [
        .target(name: "HostAudit", dependencies: [.product(name: "SanjboxProbeKit", package: "common")]),
        .executableTarget(name: "sanjbox-host-audit", dependencies: ["HostAudit"]),
        .executableTarget(name: "sanjbox-host-harden", dependencies: ["HostAudit"]),
        .testTarget(name: "HostAuditTests", dependencies: ["HostAudit"]),
    ]
)
