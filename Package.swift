// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Inphic",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "InphicCore", targets: ["InphicCore"]),
        .executable(name: "InphicHub", targets: ["InphicHub"]),
        .executable(name: "probe", targets: ["probe"]),
    ],
    targets: [
        .target(name: "InphicCore"),
        .executableTarget(name: "InphicHub", dependencies: ["InphicCore"]),
        .executableTarget(name: "probe", dependencies: ["InphicCore"]),
        .testTarget(name: "InphicCoreTests", dependencies: ["InphicCore"]),
    ]
)
