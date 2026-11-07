// swift-tools-version: 6.0
import PackageDescription

// Isolated core prototype (IMPLEMENTATION §3, stream H). No external dependencies and no
// `.package(path:)` edge: this package must stay buildable on its own and must not be linked
// into a runnable MVP.
let package = Package(
    name: "SanjboxContracts",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SanjboxContracts", targets: ["SanjboxContracts"])],
    targets: [
        .target(name: "SanjboxContracts", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "SanjboxContractsTests", dependencies: ["SanjboxContracts"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
