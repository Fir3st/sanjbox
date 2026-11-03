// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SanjboxGateway",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SanjboxGatewayCore", targets: ["SanjboxGatewayCore"]),
        .executable(name: "sanjbox-gateway", targets: ["sanjbox-gateway"]),
    ],
    dependencies: [.package(path: "../common")],
    targets: [
        .target(name: "SanjboxGatewayCore"),
        .executableTarget(name: "sanjbox-gateway", dependencies: [
            "SanjboxGatewayCore", .product(name: "SanjboxProbeKit", package: "common"),
        ]),
        .testTarget(name: "SanjboxGatewayCoreTests", dependencies: ["SanjboxGatewayCore"]),
    ]
)
