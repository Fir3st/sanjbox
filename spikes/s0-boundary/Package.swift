// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SanjboxBoundaryPreparation",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "xpc-probe", targets: ["xpc-probe"]),
        .executable(name: "tcc-probe", targets: ["tcc-probe"]),
        .executable(name: "capture-probe", targets: ["capture-probe"]),
        .executable(name: "host-read-probe", targets: ["host-read-probe"]),
        .executable(name: "ingress-probe", targets: ["ingress-probe"]),
        .executable(name: "signing-probe", targets: ["signing-probe"]),
        .executable(name: "lifecycle-probe", targets: ["lifecycle-probe"]),
    ],
    dependencies: [.package(path: "../common")],
    targets: [
        .target(name: "BoundaryKit", dependencies: [.product(name: "SanjboxProbeKit", package: "common")]),
        .executableTarget(name: "xpc-probe", dependencies: ["BoundaryKit"]),
        .executableTarget(name: "tcc-probe", dependencies: ["BoundaryKit"]),
        .executableTarget(name: "capture-probe", dependencies: ["BoundaryKit"]),
        .executableTarget(name: "host-read-probe", dependencies: ["BoundaryKit"]),
        .executableTarget(name: "ingress-probe", dependencies: ["BoundaryKit"]),
        .executableTarget(name: "signing-probe", dependencies: ["BoundaryKit"]),
        .executableTarget(name: "lifecycle-probe", dependencies: ["BoundaryKit"]),
        .testTarget(name: "BoundaryKitTests", dependencies: ["BoundaryKit"]),
    ]
)
