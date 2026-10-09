// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// Settings shared by every target.
///
/// `NonisolatedNonsendingByDefault` (SE-0461) makes nonisolated async functions
/// run on the caller's executor; use `@concurrent` for work that should move to
/// the preferred task executor. It becomes the default in a future language mode.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "SwiftExecutors",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "SwiftExecutors",
            targets: ["SwiftExecutors"]
        ),
        .executable(
            name: "SwiftExecutorsCLI",
            targets: ["SwiftExecutorsCLI"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftExecutors",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "SwiftExecutorsCLI",
            dependencies: ["SwiftExecutors"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SwiftExecutorsTests",
            dependencies: ["SwiftExecutors"],
            swiftSettings: swiftSettings
        ),
    ]
)
