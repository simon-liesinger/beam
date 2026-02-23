import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics

// Initialize GUI connection to the window server (required for screen capture)
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No dock icon or menu bar

// MARK: - Stream Output Delegate

class CaptureDelegate: NSObject, SCStreamOutput {
    var frameCount = 0
    var firstFrameTime: CFAbsoluteTime?
    var lastReportTime: CFAbsoluteTime = 0
    var framesInInterval = 0
    let maxFrames: Int

    init(maxFrames: Int = 0) {
        self.maxFrames = maxFrames
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        let now = CFAbsoluteTimeGetCurrent()

        if firstFrameTime == nil {
            firstFrameTime = now
            lastReportTime = now
            print("First frame received!")
        }

        frameCount += 1
        framesInInterval += 1

        // Report FPS every 2 seconds
        if now - lastReportTime >= 2.0 {
            let fps = Double(framesInInterval) / (now - lastReportTime)

            var sizeStr = ""
            if let pixelBuffer = sampleBuffer.imageBuffer {
                let w = CVPixelBufferGetWidth(pixelBuffer)
                let h = CVPixelBufferGetHeight(pixelBuffer)
                sizeStr = " [\(w)x\(h)]"
            }

            print("Frames: \(frameCount) | FPS: \(String(format: "%.1f", fps))\(sizeStr)")
            framesInInterval = 0
            lastReportTime = now
        }

        if maxFrames > 0 && frameCount >= maxFrames {
            let elapsed = now - (firstFrameTime ?? now)
            let avgFps = elapsed > 0 ? Double(frameCount) / elapsed : 0
            print("\nCaptured \(frameCount) frames in \(String(format: "%.1f", elapsed))s (avg \(String(format: "%.1f", avgFps)) fps)")
            print("Spike PASSED")
            exit(0)
        }
    }
}

// MARK: - Window Listing

func listWindows() async throws -> [SCWindow] {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

    let windows = content.windows.filter { window in
        guard let title = window.title, !title.isEmpty else { return false }
        guard window.frame.width > 100 && window.frame.height > 100 else { return false }
        return true
    }

    return windows
}

// MARK: - Capture

func captureWindow(_ window: SCWindow, maxFrames: Int) async throws {
    let filter = SCContentFilter(desktopIndependentWindow: window)

    let config = SCStreamConfiguration()
    config.width = Int(window.frame.width)
    config.height = Int(window.frame.height)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = true
    config.queueDepth = 3

    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
    let delegate = CaptureDelegate(maxFrames: maxFrames)

    try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))

    let appName = window.owningApplication?.applicationName ?? "Unknown"
    print("Capturing '\(appName) - \(window.title ?? "untitled")' at \(config.width)x\(config.height) @ 30fps...")
    if maxFrames > 0 {
        print("Will capture \(maxFrames) frames then exit.\n")
    } else {
        print("Press Ctrl+C to stop.\n")
    }

    try await stream.startCapture()

    // Keep running
    signal(SIGINT) { _ in
        print("\nCapture stopped.")
        exit(0)
    }

    // Block forever (or until maxFrames triggers exit)
    let semaphore = DispatchSemaphore(value: 0)
    semaphore.wait()
}

// MARK: - Main

let args = CommandLine.arguments

func printUsage() {
    print("Usage:")
    print("  ScreenCaptureSpike --list              List available windows")
    print("  ScreenCaptureSpike --capture N          Capture window N (from --list)")
    print("  ScreenCaptureSpike --capture N --frames F  Capture F frames then exit")
    print("  ScreenCaptureSpike                      Interactive mode")
}

Task {
    do {
        print("=== Beam ScreenCaptureKit Spike ===\n")

        if args.contains("--help") {
            printUsage()
            exit(0)
        }

        if args.contains("--list") {
            let windows = try await listWindows()
            if windows.isEmpty {
                print("No capturable windows found.")
                exit(1)
            }
            for (i, window) in windows.enumerated() {
                let appName = window.owningApplication?.applicationName ?? "Unknown"
                let title = window.title ?? "Untitled"
                let size = "\(Int(window.frame.width))x\(Int(window.frame.height))"
                print("[\(i)] \(appName) - \(title) (\(size))")
            }
            exit(0)
        }

        if let captureIdx = args.firstIndex(of: "--capture"),
           captureIdx + 1 < args.count,
           let windowIdx = Int(args[captureIdx + 1]) {
            let maxFrames: Int
            if let framesIdx = args.firstIndex(of: "--frames"),
               framesIdx + 1 < args.count,
               let f = Int(args[framesIdx + 1]) {
                maxFrames = f
            } else {
                maxFrames = 0
            }

            let windows = try await listWindows()
            guard windowIdx >= 0 && windowIdx < windows.count else {
                print("Window index \(windowIdx) out of range (0-\(windows.count - 1))")
                exit(1)
            }
            try await captureWindow(windows[windowIdx], maxFrames: maxFrames)
            return
        }

        // Interactive mode
        let windows = try await listWindows()
        if windows.isEmpty {
            print("No capturable windows found. Make sure Screen Recording permission is granted.")
            print("Go to: System Settings > Privacy & Security > Screen Recording")
            exit(1)
        }

        print("Available windows:\n")
        for (i, window) in windows.enumerated() {
            let appName = window.owningApplication?.applicationName ?? "Unknown"
            let title = window.title ?? "Untitled"
            let size = "\(Int(window.frame.width))x\(Int(window.frame.height))"
            print("  [\(i)] \(appName) - \(title) (\(size))")
        }

        print("\nEnter window number to capture (or press Enter for [0]): ", terminator: "")
        fflush(stdout)

        let input = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        let index = Int(input) ?? 0

        guard index >= 0 && index < windows.count else {
            print("Invalid selection.")
            exit(1)
        }

        try await captureWindow(windows[index], maxFrames: 0)

    } catch let error as NSError where error.code == -3801 {
        print("\nScreen Recording permission required.")
        print("Grant access in: System Settings > Privacy & Security > Screen Recording")
        print("Add the app running this command (e.g., Terminal, VS Code, iTerm).")
        print("You may need to restart the app after granting permission.")
        exit(1)
    } catch {
        print("Error: \(error)")
        exit(1)
    }
}

dispatchMain()
