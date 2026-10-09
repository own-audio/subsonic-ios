// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SubsonicKit",
    // macOS only so `swift test` runs on the host without a simulator.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SubsonicKit", targets: ["SubsonicKit"])
    ],
    targets: [
        .target(name: "SubsonicKit"),
        .testTarget(name: "SubsonicKitTests", dependencies: ["SubsonicKit"]),
    ]
)
