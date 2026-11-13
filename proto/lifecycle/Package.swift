// swift-tools-version: 6.0
import PackageDescription

// No external dependencies. H1 is the single source of lifecycle, manifest and audit contracts.
let package = Package(
    name: "SanjboxLifecycle", platforms: [.macOS(.v15)],
    products: [.library(name: "SanjboxLifecycle", targets: ["SanjboxLifecycle"]),
               .executable(name: "lifecycle-crash-driver", targets: ["lifecycle-crash-driver"])],
    dependencies: [.package(path: "../contracts")],
    targets: [
        .target(name: "SanjboxLifecycle", dependencies: [.product(name: "SanjboxContracts", package: "contracts")]),
        .executableTarget(name: "lifecycle-crash-driver", dependencies: ["SanjboxLifecycle"]),
        .testTarget(name: "SanjboxLifecycleTests", dependencies: ["SanjboxLifecycle", "lifecycle-crash-driver"]),
    ], swiftLanguageModes: [.v6]
)
