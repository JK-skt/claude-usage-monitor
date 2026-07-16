// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ClaudeUsageCore", targets: ["ClaudeUsageCore"]),
        .executable(name: "ClaudeUsageMonitor", targets: ["ClaudeUsageMonitorApp"]),
        .executable(name: "claude-monitor", targets: ["ClaudeMonitorCLI"]),
    ],
    targets: [
        .target(
            name: "ClaudeUsageCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "ClaudeUsageMonitorApp",
            dependencies: ["ClaudeUsageCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "ClaudeMonitorCLI",
            dependencies: ["ClaudeUsageCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "ClaudeUsageCoreTests",
            dependencies: ["ClaudeUsageCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
