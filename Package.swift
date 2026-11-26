// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LinkPool",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LinkPool", targets: ["LinkPoolApp"]),
        .executable(name: "linkpoolctl", targets: ["linkpoolctl"]),
        .library(name: "LinkPoolCore", targets: ["LinkPoolCore"]),
    ],
    targets: [
        .target(
            name: "LinkPoolCore",
            path: "Sources/LinkPoolCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LinkPoolApp",
            dependencies: ["LinkPoolCore"],
            path: "Sources/LinkPoolApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "linkpoolctl",
            dependencies: ["LinkPoolCore"],
            path: "Sources/linkpoolctl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LinkPoolCoreTests",
            dependencies: ["LinkPoolCore"],
            path: "Tests/LinkPoolCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
