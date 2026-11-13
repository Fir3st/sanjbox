// swift-tools-version: 6.0
import PackageDescription

// WP1.H5 — řízený export (prototyp, proud H). Žádné externí závislosti, žádné .package(path:).
// Nic z tohoto balíku nesestavuje běžící oblast; je to izolovaný prototyp proti mockům.
let package = Package(
    name: "SanjboxExport",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SanjboxExport", targets: ["SanjboxExport"]),
        .executable(name: "sanjbox-export", targets: ["sanjbox-export"]),
    ],
    targets: [
        .target(name: "SanjboxExport"),
        .target(name: "SanjboxExportCLI", dependencies: ["SanjboxExport"]),
        .executableTarget(name: "sanjbox-export", dependencies: ["SanjboxExportCLI"]),
        .testTarget(name: "SanjboxExportTests", dependencies: ["SanjboxExport", "SanjboxExportCLI"]),
    ]
)
