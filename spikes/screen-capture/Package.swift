// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenCaptureSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScreenCaptureSpike",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
