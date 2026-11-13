// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SanjboxCLI", platforms: [.macOS(.v15)],
    products: [.library(name: "SanjboxCLI", targets: ["SanjboxCLI"]),
               .executable(name: "sanjbox", targets: ["sanjbox"])],
    dependencies: [.package(path: "../contracts")],
    targets: [
        .target(name: "SanjboxCLI", dependencies: [.product(name: "SanjboxContracts", package: "contracts")]),
        .executableTarget(name: "sanjbox", dependencies: ["SanjboxCLI"]),
        .testTarget(name: "SanjboxCLITests", dependencies: ["SanjboxCLI", "sanjbox"]),
    ], swiftLanguageModes: [.v6]
)
