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
            // Testing.framework is in the CommandLineTools developer frameworks,
            // not the macOS SDK — need explicit paths for compiler, linker, and rpath.
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("Testing"),
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
            ]
        ),
    ]
)
