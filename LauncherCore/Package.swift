// swift-tools-version: 6.4
import PackageDescription

// Same concurrency semantics as the app target (Xcode "Approachable Concurrency"
// and member import visibility), without its default MainActor isolation.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "LauncherCore",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "LauncherCore", targets: ["LauncherCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1")
    ],
    targets: [
        .target(
            name: "LauncherCore",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            swiftSettings: swiftSettings),
        .testTarget(
            name: "LauncherCoreTests",
            dependencies: [
                "LauncherCore", .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: swiftSettings),
    ]
)
