// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MacTMUX",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "MacTMUXCore", targets: ["MacTMUXCore"]),
        .executable(name: "MacTMUX", targets: ["MacTMUXApp"])
    ],
    targets: [
        .target(
            name: "MacTMUXCore"
        ),
        .target(
            name: "MacTMUXGhosttyBridge",
            path: "Sources/MacTMUXGhosttyBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "MacTMUXApp",
            dependencies: ["MacTMUXCore", "MacTMUXGhosttyBridge"]
        ),
        .testTarget(
            name: "MacTMUXCoreTests",
            dependencies: ["MacTMUXCore"]
        ),
        .testTarget(
            name: "MacTMUXAppTests",
            dependencies: ["MacTMUXApp", "MacTMUXCore"]
        )
    ]
)
