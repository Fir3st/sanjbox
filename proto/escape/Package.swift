// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SanjboxEscape", platforms: [.macOS(.v15)],
    products: [.library(name: "SanjboxEscape", targets: ["SanjboxEscape"]),
               .executable(name: "sanjbox-escape", targets: ["sanjbox-escape"])],
    dependencies: [.package(path: "../contracts"), .package(path: "../../spikes/common")],
    targets: [
        .target(name: "SanjboxEscape", dependencies: [
            .product(name: "SanjboxContracts", package: "contracts"),
            .product(name: "SanjboxProbeKit", package: "common")
        ], resources: [.copy("Resources/catalog.json")]),
        .executableTarget(name: "sanjbox-escape", dependencies: ["SanjboxEscape"]),
        .testTarget(name: "SanjboxEscapeTests", dependencies: ["SanjboxEscape", "sanjbox-escape"])
    ], swiftLanguageModes: [.v6]
)
