// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SanjboxStateManifest",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "sanjbox-state-manifest", targets: ["sanjbox-state-manifest"])],
    dependencies: [.package(path: "../common")],
    targets: [
        .target(name: "StateManifest", dependencies: [.product(name: "SanjboxProbeKit", package: "common")]),
        .executableTarget(name: "sanjbox-state-manifest", dependencies: ["StateManifest"]),
        .testTarget(name: "StateManifestTests", dependencies: ["StateManifest"]),
    ]
)
