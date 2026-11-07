// swift-tools-version: 6.4
import PackageDescription
let package = Package(
    name: "SanjboxIngressPreparation", platforms: [.macOS(.v15)],
    products: [.executable(name: "sanjbox-ingress", targets: ["sanjbox-ingress"])],
    dependencies: [.package(path: "../../common")],
    targets: [
        .target(name: "IngressKit", dependencies: [.product(name: "SanjboxProbeKit", package: "common"), .product(name: "SanjboxNetworkProvenance", package: "common")]),
        .executableTarget(name: "sanjbox-ingress", dependencies: ["IngressKit"]),
        .testTarget(name: "IngressKitTests", dependencies: ["IngressKit"], resources: [.copy("Fixtures")])
    ])
