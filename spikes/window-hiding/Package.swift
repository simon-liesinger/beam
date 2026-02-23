// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowHidingSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CVirtualDisplay",
            path: "Sources/CVirtualDisplay",
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "WindowHidingSpike",
            dependencies: ["CVirtualDisplay"],
            path: "Sources",
            exclude: ["CVirtualDisplay"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
    ]
)
