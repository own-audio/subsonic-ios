// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlayerEngine",
    // macOS only so `swift test` runs on the host without a simulator.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PlayerEngine", targets: ["PlayerEngine"])
    ],
    targets: [
        .target(name: "PlayerEngine"),
        .testTarget(
            name: "PlayerEngineTests",
            dependencies: ["PlayerEngine"],
            // Short synthesized tones, so the decoder is tested against real audio bytes.
            resources: [.copy("Fixtures")]
        ),
    ]
)
