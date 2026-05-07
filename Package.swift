// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacTMUX",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacTMUXCore", targets: ["MacTMUXCore"]),
        .executable(name: "MacTMUX", targets: ["MacTMUXApp"])
    ],
    targets: [
        .target(
            name: "MacTMUXCore"
        ),
        .executableTarget(
            name: "MacTMUXApp",
            dependencies: ["MacTMUXCore"]
        ),
        .testTarget(
            name: "MacTMUXCoreTests",
            dependencies: ["MacTMUXCore"]
        )
    ]
)
