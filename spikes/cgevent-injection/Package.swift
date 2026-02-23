// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CGEventSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CGEventSpike",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
