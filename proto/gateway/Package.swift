// swift-tools-version: 6.0
import PackageDescription

// WP1.H4 — prototyp brány jako služby. Jediná závislost je lokální cesta na
// spike WP1.D1–D5 (`spikes/s5-gateway`); žádný externí balíček.
let package = Package(
    name: "SanjboxGatewayService",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SanjboxGatewayService", targets: ["SanjboxGatewayService"]),
        .executable(name: "sanjbox-gateway-service", targets: ["sanjbox-gateway-service"]),
    ],
    dependencies: [
        .package(path: "../../spikes/s5-gateway"),
    ],
    targets: [
        .target(
            name: "SanjboxGatewayService",
            dependencies: [.product(name: "SanjboxGatewayCore", package: "s5-gateway")]
        ),
        .executableTarget(
            name: "sanjbox-gateway-service",
            dependencies: ["SanjboxGatewayService"]
        ),
        .testTarget(
            name: "SanjboxGatewayServiceTests",
            dependencies: [
                "SanjboxGatewayService",
                .product(name: "SanjboxGatewayCore", package: "s5-gateway"),
            ]
        ),
    ]
)
