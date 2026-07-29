// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "basalt-streamer",
    platforms: [.macOS(.v14)],
    targets: [
        // Capture/encode/transport building blocks, kept in a library so
        // they can be unit-tested and reused by later milestones (ALVR
        // bridge, OpenXR runtime daemon).
        .target(name: "BasaltCore"),
        .target(name: "BasaltBottleKit"),
        .target(
            name: "BasaltManagerKit",
            dependencies: ["BasaltCore", "BasaltBottleKit"]
        ),
        .executableTarget(
            name: "basalt-streamer",
            dependencies: ["BasaltCore"],
            path: "Sources/BasaltStreamer"
        ),
        .executableTarget(
            name: "basaltctl",
            dependencies: ["BasaltBottleKit"],
            path: "Sources/BasaltCLI"
        ),
        .executableTarget(
            name: "BasaltVR",
            dependencies: ["BasaltManagerKit", "BasaltBottleKit", "BasaltCore"],
            path: "Sources/BasaltManager"
        ),
        .testTarget(
            name: "BasaltCoreTests",
            dependencies: ["BasaltCore"]
        ),
        .testTarget(
            name: "BasaltBottleKitTests",
            dependencies: ["BasaltBottleKit"]
        ),
        .testTarget(
            name: "BasaltManagerKitTests",
            dependencies: ["BasaltManagerKit", "BasaltBottleKit", "BasaltCore"]
        ),
    ]
)
