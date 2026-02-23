// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VideoToolboxSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VideoToolboxSpike",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Network"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
    ]
)
