// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SanjboxRFBResearch",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RFBProtocol", targets: ["RFBProtocol"]),
        .executable(name: "sanjbox-rfb-fixture", targets: ["sanjbox-rfb-fixture"]),
    ],
    targets: [
        .target(name: "RFBProtocol"),
        .executableTarget(name: "sanjbox-rfb-fixture", dependencies: ["RFBProtocol"]),
        .testTarget(name: "RFBProtocolTests", dependencies: ["RFBProtocol"]),
    ]
)
