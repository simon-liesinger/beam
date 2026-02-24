// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BeamMac",
    platforms: [.macOS(.v14)],
    targets: [
        // All reusable code — imported by the executable and by tests
        .target(
            name: "BeamMacCore",
            path: "Sources/BeamMacCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
        // Thin entry point — just main.swift
        .executableTarget(
            name: "BeamMac",
            dependencies: ["BeamMacCore"],
            path: "Sources/BeamMac",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "BeamMacTests",
            dependencies: ["BeamMacCore"],
            path: "Tests/BeamMacTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
