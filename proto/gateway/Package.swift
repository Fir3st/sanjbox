// swift-tools-version: 6.0
import PackageDescription

// WP1.H4: local H1 contracts and D1–D5 handlers; no external packages.
let package = Package(
    name: "SanjboxGatewayService",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SanjboxGatewayService", targets: ["SanjboxGatewayService"]),
        .executable(name: "sanjbox-gateway-service", targets: ["sanjbox-gateway-service"]),
    ],
    dependencies: [
        .package(path: "../../spikes/s5-gateway"),
        .package(path: "../contracts"),
    ],
    targets: [
        .target(
            name: "SanjboxGatewayService",
            dependencies: [.product(name: "SanjboxGatewayCore", package: "s5-gateway"),
                           .product(name: "SanjboxContracts", package: "contracts")]
        ),
        .executableTarget(
            name: "sanjbox-gateway-service",
            dependencies: ["SanjboxGatewayService"]
        ),
        .testTarget(
            name: "SanjboxGatewayServiceTests",
            dependencies: [
                "SanjboxGatewayService",
                .product(name: "SanjboxContracts", package: "contracts"),
                .product(name: "SanjboxGatewayCore", package: "s5-gateway"),
            ]
        ),
    ]
)
