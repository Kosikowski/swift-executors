// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftExecutors",
    platforms: [
        .iOS(.v17),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "SwiftExecutors",
            targets: ["SwiftExecutors"]
        ),
        .executable( // New executable product
            name: "SwiftExecutorsCLI",
            targets: ["SwiftExecutorsCLI"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftExecutors"),
        .executableTarget( // New executable target
            name: "SwiftExecutorsCLI",
            dependencies: ["SwiftExecutors"] // Add dependency to the main library if needed
        ),
        .testTarget(
            name: "SwiftExecutorsTests",
            dependencies: ["SwiftExecutors"]
        ),
    ]
)
