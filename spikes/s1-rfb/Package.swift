// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SanjboxRFBResearch",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "RFBProtocol", targets: ["RFBProtocol"]),
        .executable(name: "sanjbox-rfb-fixture", targets: ["sanjbox-rfb-fixture"]),
        .executable(name: "sanjbox-ard-worker", targets: ["sanjbox-ard-worker"]),
    ],
    targets: [
        .target(name: "RFBProtocol", dependencies: ["CArdWorkerRunner"]),
        .target(name: "CArdCrypto"),
        .target(name: "CArdWorkerRunner"),
        .target(name: "CArdCryptoTestSupport", path: "Tests/CArdCryptoTestSupport"),
        .executableTarget(name: "sanjbox-ard-worker", dependencies: ["CArdCrypto"]),
        .executableTarget(name: "ard-worker-test-fixture", dependencies: ["CArdWorkerRunner"], path: "Tests/WorkerFixture"),
        .executableTarget(name: "sanjbox-rfb-fixture", dependencies: ["RFBProtocol"]),
        .testTarget(name: "RFBProtocolTests", dependencies: ["RFBProtocol", "CArdCryptoTestSupport"],
                    resources: [.copy("Fixtures")]),
    ]
)
