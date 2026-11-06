// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SanjboxGatewayFixtures",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SanjboxGatewayFixtures", targets: ["SanjboxGatewayFixtures"])],
    dependencies: [.package(path: "../s5-gateway")],
    targets: [
        .target(name: "SanjboxGatewayFixtures", dependencies: [
            .product(name: "SanjboxGatewayCore", package: "s5-gateway"),
        ]),
        .testTarget(name: "SanjboxGatewayFixturesTests", dependencies: [
            "SanjboxGatewayFixtures",
            .product(name: "SanjboxGatewayCore", package: "s5-gateway"),
        ]),
    ]
)
