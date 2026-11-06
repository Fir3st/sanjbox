// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SanjboxS3Preparation",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "sanjbox-s3-probe", targets: ["sanjbox-s3-probe"])],
    dependencies: [.package(path: "../common")],
    targets: [
        .target(name: "C1ProbeKit", dependencies: [.product(name: "SanjboxProbeKit", package: "common"), .product(name: "SanjboxNetworkProvenance", package: "common")]),
        .executableTarget(name: "sanjbox-s3-probe", dependencies: ["C1ProbeKit"]),
        .testTarget(name: "C1ProbeKitTests", dependencies: ["C1ProbeKit"]),
    ]
)
