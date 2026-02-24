// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioCaptureSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AudioCaptureSpike",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ]),
            ]
        ),
    ]
)
