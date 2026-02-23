// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BeamMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BeamMac",
            path: "Sources/BeamMac",
            swiftSettings: [
                // Required for @main App protocol entry point in SPM executable targets
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        )
    ]
)
