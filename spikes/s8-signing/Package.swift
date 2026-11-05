// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "S8SigningPreparation",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "s8-probe", targets: ["s8-probe"])] +
        ["S8ServiceHost", "S8LoginItem", "S8LaunchAgent", "S8LaunchDaemon"].map { .executable(name: $0, targets: [$0]) },
    dependencies: [.package(path: "../common")],
    targets: [
        .target(name: "S8Preparation", dependencies: [.product(name: "SanjboxProbeKit", package: "common")]),
        .executableTarget(name: "s8-probe", dependencies: ["S8Preparation", .product(name: "SanjboxProbeKit", package: "common")]),
        .testTarget(name: "S8PreparationTests", dependencies: ["S8Preparation"]),
    ] + ["S8ServiceHost", "S8LoginItem", "S8LaunchAgent", "S8LaunchDaemon"].map {
        .executableTarget(name: $0, dependencies: ["S8Preparation", .product(name: "SanjboxProbeKit", package: "common")])
    }
)
