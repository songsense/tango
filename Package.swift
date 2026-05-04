// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeTool",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ClaudeToolApp", targets: ["ClaudeToolApp"]),
        .executable(name: "tango", targets: ["tango"]),
        .library(name: "ClaudeToolCore", targets: ["ClaudeToolCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "ClaudeToolCore",
            path: "Sources/ClaudeToolCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("SoundAnalysis")
            ]
        ),
        .executableTarget(
            name: "ClaudeToolApp",
            dependencies: ["ClaudeToolCore"],
            path: "Sources/ClaudeToolApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .executableTarget(
            name: "tango",
            dependencies: [
                "ClaudeToolCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/tango"
        ),
        .testTarget(
            name: "ClaudeToolCoreTests",
            dependencies: ["ClaudeToolCore"],
            path: "Tests/ClaudeToolCoreTests"
        ),
        .testTarget(
            name: "PatDetectorTests",
            dependencies: ["ClaudeToolCore"],
            path: "Tests/PatDetectorTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
