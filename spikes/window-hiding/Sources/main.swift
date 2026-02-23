import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import CVirtualDisplay

setbuf(stdout, nil)

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let targetFPS: Int32 = 30

// MARK: - Frame Counter (thread-safe)

class FrameCounter {
    private let lock = NSLock()
    private var _count: Int = 0
    private var _total: Int = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }

    var total: Int {
        lock.lock(); defer { lock.unlock() }
        return _total
    }

    func increment() {
        lock.lock()
        _count += 1
        _total += 1
        lock.unlock()
    }

    func reset() -> Int {
        lock.lock()
        let c = _count
        _count = 0
        lock.unlock()
        return c
    }
}

// MARK: - Window Capturer

class WindowCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    let frameCounter = FrameCounter()

    func startCapture(window: SCWindow, width: Int, height: Int) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: targetFPS)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 3

        for attempt in 1...3 {
            do {
                stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream!.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
                try await stream!.startCapture()
                return
            } catch {
                print("  Capture attempt \(attempt) failed: \(error.localizedDescription)")
                stream = nil
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } else {
                    throw error
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.imageBuffer != nil else { return }
        frameCounter.increment()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("  Capture ERROR: \(error.localizedDescription)")
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stopSync() {
        guard let s = stream else { return }
        let sem = DispatchSemaphore(value: 0)
        Task {
            try? await s.stopCapture()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2.0)
        stream = nil
    }
}

// MARK: - AXUIElement Helpers

func getAXWindow(pid: pid_t, title: String? = nil) -> AXUIElement? {
    let appElement = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
    guard result == .success, let windows = windowsRef as? [AXUIElement] else {
        return nil
    }

    // List all AX windows for debugging
    print("  AX windows for PID \(pid) (\(windows.count) total):")
    for (i, win) in windows.enumerated() {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
        let winTitle = (titleRef as? String) ?? "<no title>"
        let pos = getWindowPosition(win)
        let posStr = pos.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "?"
        print("    [\(i)] \"\(winTitle)\" at \(posStr)")
    }

    // If title provided, find matching window
    if let title = title {
        for win in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            if let winTitle = titleRef as? String, winTitle.contains(title) {
                print("  Matched AX window: \"\(winTitle)\"")
                return win
            }
        }
        print("  WARNING: No AX window matched title \"\(title)\", falling back to first")
    }

    return windows.first
}

func getWindowPosition(_ window: AXUIElement) -> CGPoint? {
    var posRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
    guard result == .success, let posValue = posRef else { return nil }
    var point = CGPoint.zero
    AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
    return point
}

func setWindowPosition(_ window: AXUIElement, _ point: CGPoint) -> Bool {
    var p = point
    guard let value = AXValueCreate(.cgPoint, &p) else { return false }
    return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
}

func getWindowSize(_ window: AXUIElement) -> CGSize? {
    var sizeRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
    guard result == .success, let sizeValue = sizeRef else { return nil }
    var size = CGSize.zero
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    return size
}

func minimizeWindow(_ window: AXUIElement) -> Bool {
    return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
}

func unminimizeWindow(_ window: AXUIElement) -> Bool {
    return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
}

func isMinimized(_ window: AXUIElement) -> Bool {
    var ref: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &ref)
    return (ref as? Bool) == true
}

func hideApp(pid: pid_t) {
    let app = NSRunningApplication(processIdentifier: pid)
    app?.hide()
}

func unhideApp(pid: pid_t) {
    let app = NSRunningApplication(processIdentifier: pid)
    app?.unhide()
}

func raiseWindow(_ window: AXUIElement) {
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
}

// MARK: - Test Helpers

/// Measure fps over a given duration
func measureFPS(counter: FrameCounter, duration: TimeInterval) -> Double {
    counter.reset()
    Thread.sleep(forTimeInterval: duration)
    let frames = counter.reset()
    return Double(frames) / duration
}

/// Print a test result line
func printResult(_ testName: String, fps: Double, pass: Bool) {
    let status = pass ? "PASS" : "FAIL"
    let fpsStr = String(format: "%.1f", fps)
    print("  [\(status)] \(testName): \(fpsStr) fps")
}

// MARK: - Window Listing

func listWindows() async throws -> [SCWindow] {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    return content.windows.filter { window in
        guard let title = window.title, !title.isEmpty else { return false }
        guard window.frame.width > 100 && window.frame.height > 100 else { return false }
        return true
    }
}

// MARK: - Main Test Suite

func runTests(window: SCWindow) async throws {
    let pid = window.owningApplication?.processID ?? 0
    let appName = window.owningApplication?.applicationName ?? "?"
    let width = Int(window.frame.width)
    let height = Int(window.frame.height)

    print("\n=== Window Hiding Spike ===")
    print("Target: \(appName) - \(window.title ?? "?") (\(width)x\(height), PID \(pid))")

    // Get AX handle - match by window title
    guard let axWindow = getAXWindow(pid: pid, title: window.title) else {
        print("ERROR: Could not get AXUIElement for window. Is Accessibility permission granted?")
        return
    }

    guard let originalPos = getWindowPosition(axWindow) else {
        print("ERROR: Could not read window position")
        return
    }
    print("Original position: (\(Int(originalPos.x)), \(Int(originalPos.y)))")

    // Start capture
    let capturer = WindowCapturer()
    print("\nStarting capture...")
    try await capturer.startCapture(window: window, width: width, height: height)
    print("Capture started. Waiting 2s for stream to stabilize...\n")
    try await Task.sleep(nanoseconds: 2_000_000_000)

    let testDuration: TimeInterval = 4.0
    let fpsThreshold: Double = 1.0  // >1fps = frames are flowing

    // --- Test 1: Baseline (normal, visible window) ---
    print("Test 1: BASELINE (normal visible window)")
    let baselineFPS = measureFPS(counter: capturer.frameCounter, duration: testDuration)
    printResult("Baseline", fps: baselineFPS, pass: baselineFPS > 10)

    // --- Test 2: Off-screen (x = -10000) ---
    print("\nTest 2: OFF-SCREEN (move to x=-10000)")
    let moved = setWindowPosition(axWindow, CGPoint(x: -10000, y: originalPos.y))
    print("  Moved off-screen: \(moved)")
    Thread.sleep(forTimeInterval: 1.0)  // Let compositor settle
    let offscreenFPS = measureFPS(counter: capturer.frameCounter, duration: testDuration)
    printResult("Off-screen (x=-10000)", fps: offscreenFPS, pass: offscreenFPS > fpsThreshold)
    // Restore
    _ = setWindowPosition(axWindow, originalPos)
    Thread.sleep(forTimeInterval: 1.0)

    // --- Test 3: Off-screen (y = -10000) ---
    print("\nTest 3: OFF-SCREEN (move to y=-10000)")
    let movedY = setWindowPosition(axWindow, CGPoint(x: originalPos.x, y: -10000))
    print("  Moved off-screen: \(movedY)")
    Thread.sleep(forTimeInterval: 1.0)
    let offscreenYFPS = measureFPS(counter: capturer.frameCounter, duration: testDuration)
    printResult("Off-screen (y=-10000)", fps: offscreenYFPS, pass: offscreenYFPS > fpsThreshold)
    _ = setWindowPosition(axWindow, originalPos)
    Thread.sleep(forTimeInterval: 1.0)

    // --- Test 4: Fully occluded (behind another window) ---
    print("\nTest 4: OCCLUDED (behind a large window)")
    // Create a window that covers the target
    let occluderSem = DispatchSemaphore(value: 0)
    var occluderWindow: NSWindow!
    DispatchQueue.main.async {
        let screen = NSScreen.main!.frame
        occluderWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: screen.width, height: screen.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        occluderWindow.backgroundColor = .red
        occluderWindow.level = .floating
        occluderWindow.makeKeyAndOrderFront(nil)
        occluderSem.signal()
    }
    occluderSem.wait()
    Thread.sleep(forTimeInterval: 1.0)
    let occludedFPS = measureFPS(counter: capturer.frameCounter, duration: testDuration)
    printResult("Occluded (behind window)", fps: occludedFPS, pass: occludedFPS > fpsThreshold)
    DispatchQueue.main.async {
        occluderWindow.close()
    }
    Thread.sleep(forTimeInterval: 1.0)

    // --- Test 5: Minimized ---
    print("\nTest 5: MINIMIZED (Dock minimize)")
    let didMinimize = minimizeWindow(axWindow)
    print("  Minimized: \(didMinimize)")
    Thread.sleep(forTimeInterval: 1.5)  // Animation time
    let minimizedFPS = measureFPS(counter: capturer.frameCounter, duration: testDuration)
    printResult("Minimized", fps: minimizedFPS, pass: minimizedFPS > fpsThreshold)
    // Restore
    let didUnminimize = unminimizeWindow(axWindow)
    print("  Restored: \(didUnminimize)")
    Thread.sleep(forTimeInterval: 1.5)

    // --- Test 6: App hidden (Cmd+H equivalent) ---
    print("\nTest 6: APP HIDDEN (NSRunningApplication.hide)")
    hideApp(pid: pid)
    Thread.sleep(forTimeInterval: 1.0)
    let hiddenFPS = measureFPS(counter: capturer.frameCounter, duration: testDuration)
    printResult("App hidden", fps: hiddenFPS, pass: hiddenFPS > fpsThreshold)
    // Restore
    unhideApp(pid: pid)
    Thread.sleep(forTimeInterval: 1.0)

    // --- Test 7: Off-screen + occluded (belt and suspenders) ---
    print("\nTest 7: OFF-SCREEN + OCCLUDED (x=-10000 + window on top)")
    _ = setWindowPosition(axWindow, CGPoint(x: -10000, y: originalPos.y))
    let occluderSem2 = DispatchSemaphore(value: 0)
    var occluderWindow2: NSWindow!
    DispatchQueue.main.async {
        let screen = NSScreen.main!.frame
        occluderWindow2 = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: screen.width, height: screen.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        occluderWindow2.backgroundColor = .blue
        occluderWindow2.level = .floating
        occluderWindow2.makeKeyAndOrderFront(nil)
        occluderSem2.signal()
    }
    occluderSem2.wait()
    Thread.sleep(forTimeInterval: 1.0)
    let comboFPS = measureFPS(counter: capturer.frameCounter, duration: testDuration)
    printResult("Off-screen + occluded", fps: comboFPS, pass: comboFPS > fpsThreshold)
    DispatchQueue.main.async {
        occluderWindow2.close()
    }
    _ = setWindowPosition(axWindow, originalPos)
    Thread.sleep(forTimeInterval: 1.0)

    // --- Summary ---
    print("\n=== SUMMARY ===")
    print(String(format: "  Baseline:              %6.1f fps", baselineFPS))
    print(String(format: "  Off-screen (x=-10000): %6.1f fps  %@", offscreenFPS, offscreenFPS > fpsThreshold ? "OK" : "BLOCKED"))
    print(String(format: "  Off-screen (y=-10000): %6.1f fps  %@", offscreenYFPS, offscreenYFPS > fpsThreshold ? "OK" : "BLOCKED"))
    print(String(format: "  Occluded:              %6.1f fps  %@", occludedFPS, occludedFPS > fpsThreshold ? "OK" : "BLOCKED"))
    print(String(format: "  Minimized:             %6.1f fps  %@", minimizedFPS, minimizedFPS > fpsThreshold ? "OK" : "BLOCKED"))
    print(String(format: "  App hidden:            %6.1f fps  %@", hiddenFPS, hiddenFPS > fpsThreshold ? "OK" : "BLOCKED"))
    print(String(format: "  Off-screen + occluded: %6.1f fps  %@", comboFPS, comboFPS > fpsThreshold ? "OK" : "BLOCKED"))

    let bestStrategy: String
    if offscreenFPS > fpsThreshold {
        bestStrategy = "Off-screen (x=-10000) - window invisible to user, capture continues"
    } else if occludedFPS > fpsThreshold {
        bestStrategy = "Occluded - cover with another window"
    } else {
        bestStrategy = "No viable hiding strategy found!"
    }
    print("\n  Best strategy: \(bestStrategy)")
    print("  Total frames captured: \(capturer.frameCounter.total)")

    // Clean up
    print("\nStopping capture...")
    await capturer.stop()
    raiseWindow(axWindow)
    print("Done.")
}

// MARK: - CGS Private API Declarations

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> UInt32

@_silgen_name("CGSSetWindowAlpha")
func CGSSetWindowAlpha(_ cid: UInt32, _ wid: UInt32, _ alpha: Float) -> Int32

@_silgen_name("CGSMoveWindow")
func CGSMoveWindow(_ cid: UInt32, _ wid: UInt32, _ point: UnsafePointer<CGPoint>) -> Int32

@_silgen_name("CGSSetWindowTransform")
func CGSSetWindowTransform(_ cid: UInt32, _ wid: UInt32, _ transform: CGAffineTransform) -> Int32

// MARK: - Off-screen Only Test (enhanced with multiple strategies)

func runOffscreenOnly(window: SCWindow) async throws {
    let pid = window.owningApplication?.processID ?? 0
    let appName = window.owningApplication?.applicationName ?? "?"
    let width = Int(window.frame.width)
    let height = Int(window.frame.height)
    let windowID = UInt32(window.windowID)

    print("\n=== Window Hiding Strategies Test ===")
    print("Target: \(appName) - \(window.title ?? "?") (\(width)x\(height), PID \(pid), windowID \(windowID))")

    guard let axWindow = getAXWindow(pid: pid, title: window.title) else {
        print("ERROR: Could not get AXUIElement. Accessibility permission?")
        return
    }

    guard let originalPos = getWindowPosition(axWindow) else {
        print("ERROR: Could not read window position")
        return
    }
    print("Original position: (\(Int(originalPos.x)), \(Int(originalPos.y)))")

    let capturer = WindowCapturer()
    print("\nStarting capture...")
    try await capturer.startCapture(window: window, width: width, height: height)
    print("Capture started. Waiting 2s to stabilize...\n")
    try await Task.sleep(nanoseconds: 2_000_000_000)

    let testDuration: TimeInterval = 4.0
    let cid = CGSMainConnectionID()
    print("CGS connection ID: \(cid)\n")

    // --- Baseline ---
    print("Test 1: BASELINE")
    let baselineFPS = measureFPS(counter: capturer.frameCounter, duration: testDuration)
    print("  Result: \(String(format: "%.1f", baselineFPS)) fps\n")

    // --- AX off-screen (x = -10000, gets clamped) ---
    print("Test 2: AX OFF-SCREEN (x=-10000)")
    _ = setWindowPosition(axWindow, CGPoint(x: -10000, y: originalPos.y))
    Thread.sleep(forTimeInterval: 0.5)
    let axPos = getWindowPosition(axWindow)
    print("  Actual position: \(axPos.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "?")")
    let axFPS = measureFPS(counter: capturer.frameCounter, duration: testDuration)
    print("  Result: \(String(format: "%.1f", axFPS)) fps")
    _ = setWindowPosition(axWindow, originalPos)
    Thread.sleep(forTimeInterval: 0.5)

    // --- AX off-screen (x = -(width-1), exact edge) ---
    print("\nTest 3: AX EXACT EDGE (x=\(-width + 1))")
    _ = setWindowPosition(axWindow, CGPoint(x: CGFloat(-width + 1), y: originalPos.y))
    Thread.sleep(forTimeInterval: 0.5)
    let exactPos = getWindowPosition(axWindow)
    print("  Actual position: \(exactPos.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "?")")
    let exactFPS = measureFPS(counter: capturer.frameCounter, duration: testDuration)
    print("  Result: \(String(format: "%.1f", exactFPS)) fps")
    _ = setWindowPosition(axWindow, originalPos)
    Thread.sleep(forTimeInterval: 0.5)

    // --- CGSSetWindowAlpha = 0 ---
    print("\nTest 4: CGS ALPHA = 0 (window invisible, backing store should remain)")
    let alphaResult = CGSSetWindowAlpha(cid, windowID, 0.0)
    print("  CGSSetWindowAlpha returned: \(alphaResult) (0=success)")
    Thread.sleep(forTimeInterval: 0.5)
    let alphaFPS = measureFPS(counter: capturer.frameCounter, duration: testDuration)
    print("  Result: \(String(format: "%.1f", alphaFPS)) fps")
    // Restore
    CGSSetWindowAlpha(cid, windowID, 1.0)
    Thread.sleep(forTimeInterval: 0.5)

    // --- CGSMoveWindow far off-screen ---
    print("\nTest 5: CGS MOVE (x=-10000, bypassing AX clamp?)")
    var farPoint = CGPoint(x: -10000, y: originalPos.y)
    let moveResult = CGSMoveWindow(cid, windowID, &farPoint)
    print("  CGSMoveWindow returned: \(moveResult) (0=success)")
    Thread.sleep(forTimeInterval: 0.5)
    let movPos = getWindowPosition(axWindow)
    print("  AX reports position: \(movPos.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "?")")
    let cgsMovesFPS = measureFPS(counter: capturer.frameCounter, duration: testDuration)
    print("  Result: \(String(format: "%.1f", cgsMovesFPS)) fps")
    // Restore via AX
    _ = setWindowPosition(axWindow, originalPos)
    Thread.sleep(forTimeInterval: 0.5)

    // --- CGSSetWindowTransform (translate far) ---
    print("\nTest 6: CGS TRANSFORM (translate x=-50000)")
    let xformResult = CGSSetWindowTransform(cid, windowID, CGAffineTransform(translationX: -50000, y: 0))
    print("  CGSSetWindowTransform returned: \(xformResult) (0=success)")
    Thread.sleep(forTimeInterval: 0.5)
    let xformFPS = measureFPS(counter: capturer.frameCounter, duration: testDuration)
    print("  Result: \(String(format: "%.1f", xformFPS)) fps")
    // Restore
    CGSSetWindowTransform(cid, windowID, .identity)
    Thread.sleep(forTimeInterval: 0.5)

    // --- CGS Alpha 0 + AX off-screen (belt and suspenders) ---
    print("\nTest 7: CGS ALPHA 0 + AX OFF-SCREEN (combo)")
    CGSSetWindowAlpha(cid, windowID, 0.0)
    _ = setWindowPosition(axWindow, CGPoint(x: -10000, y: originalPos.y))
    Thread.sleep(forTimeInterval: 0.5)
    let comboFPS = measureFPS(counter: capturer.frameCounter, duration: testDuration)
    print("  Result: \(String(format: "%.1f", comboFPS)) fps")
    CGSSetWindowAlpha(cid, windowID, 1.0)
    _ = setWindowPosition(axWindow, originalPos)
    raiseWindow(axWindow)
    Thread.sleep(forTimeInterval: 0.5)

    // --- Summary ---
    print("\n=== SUMMARY ===")
    let tests: [(String, Double)] = [
        ("Baseline", baselineFPS),
        ("AX off-screen (clamped)", axFPS),
        ("AX exact edge", exactFPS),
        ("CGS alpha=0", alphaFPS),
        ("CGS move x=-10000", cgsMovesFPS),
        ("CGS transform", xformFPS),
        ("CGS alpha + AX offscreen", comboFPS),
    ]
    for (name, fps) in tests {
        let status = fps > 1.0 ? "OK" : "BLOCKED"
        print(String(format: "  %-28s %6.1f fps  %@", (name as NSString).utf8String!, fps, status))
    }

    await capturer.stop()
    print("\nDone.")
}

// MARK: - Virtual Display Test

func runVirtualDisplayTest(window: SCWindow) async throws {
    let pid = window.owningApplication?.processID ?? 0
    let appName = window.owningApplication?.applicationName ?? "?"
    let width = Int(window.frame.width)
    let height = Int(window.frame.height)

    print("\n=== Virtual Display Hiding Test ===")
    print("Target: \(appName) - \(window.title ?? "?") (\(width)x\(height), PID \(pid))")

    guard let axWindow = getAXWindow(pid: pid, title: window.title) else {
        print("ERROR: Could not get AXUIElement. Accessibility permission?")
        return
    }

    guard let originalPos = getWindowPosition(axWindow) else {
        print("ERROR: Could not read window position")
        return
    }
    print("Original position: (\(Int(originalPos.x)), \(Int(originalPos.y)))")

    // Step 1: Create a small virtual display (just big enough for the target window)
    print("\nCreating virtual display...")
    let vWidth = UInt(max(width, 1920))
    let vHeight = UInt(max(height, 1080))
    let desc = CGVirtualDisplayDescriptor()
    desc.setDispatchQueue(DispatchQueue.main)
    desc.terminationHandler = { _, _ in
        print("  Virtual display terminated")
    }
    desc.name = "Beam Hidden Display"
    desc.maxPixelsWide = UInt32(vWidth)
    desc.maxPixelsHigh = UInt32(vHeight)
    desc.sizeInMillimeters = CGSize(width: 600, height: 340)
    desc.productID = 0xBEA0
    desc.vendorID = 0xBEA0
    desc.serialNum = 0x0001

    guard let vDisplay = CGVirtualDisplay(descriptor: desc) else {
        print("ERROR: Failed to create virtual display")
        return
    }
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 0
    settings.modes = [
        CGVirtualDisplayMode(width: vWidth, height: vHeight, refreshRate: 60)
    ]
    let applied = vDisplay.apply(settings)
    let displayID = vDisplay.displayID
    print("  Created: displayID=\(displayID), applied=\(applied)")

    // Check where macOS placed it
    Thread.sleep(forTimeInterval: 1.0)
    let initialBounds = CGDisplayBounds(displayID)
    print("  Initial bounds: origin=(\(Int(initialBounds.origin.x)), \(Int(initialBounds.origin.y))) size=\(Int(initialBounds.width))x\(Int(initialBounds.height))")

    // List all displays to understand the coordinate space
    var displayCount: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &displayCount)
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    CGGetActiveDisplayList(displayCount, &displays, &displayCount)
    print("  Active displays (\(displayCount)):")
    for d in displays {
        let b = CGDisplayBounds(d)
        let isMain = CGDisplayIsMain(d) != 0
        let isVirtual = d == displayID
        print("    Display \(d): origin=(\(Int(b.origin.x)),\(Int(b.origin.y))) size=\(Int(b.width))x\(Int(b.height))\(isMain ? " [MAIN]" : "")\(isVirtual ? " [VIRTUAL]" : "")")
    }

    // Step 2: Position at bottom-left corner with 1px shared edge
    let mainBounds = CGDisplayBounds(CGMainDisplayID())
    let cornerX = Int32(-Int32(vWidth) + 1)  // 1px overlap with main display's left edge
    let belowY = Int32(mainBounds.origin.y + mainBounds.height)
    print("  Positioning at bottom-left corner (\(cornerX), \(belowY))...")
    var config: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&config)
    CGConfigureDisplayOrigin(config, displayID, cornerX, belowY)
    let posResult = CGCompleteDisplayConfiguration(config, .forSession)
    Thread.sleep(forTimeInterval: 0.5)

    let newBounds = CGDisplayBounds(displayID)
    print("  Position result: \(posResult.rawValue), actual: (\(Int(newBounds.origin.x)),\(Int(newBounds.origin.y)))")

    // Step 3: Start capture
    let capturer = WindowCapturer()
    print("\nStarting capture...")
    try await capturer.startCapture(window: window, width: width, height: height)
    print("Capture started. Waiting 2s to stabilize...\n")
    try await Task.sleep(nanoseconds: 2_000_000_000)

    let testDuration: TimeInterval = 5.0

    // Baseline
    print("Phase 1: BASELINE (visible, normal position)")
    let baselineFPS = measureFPS(counter: capturer.frameCounter, duration: testDuration)
    print("  Result: \(String(format: "%.1f", baselineFPS)) fps\n")

    // Move to virtual display
    let vdPos = CGPoint(x: newBounds.origin.x + 100, y: newBounds.origin.y + 100)
    print("Phase 2: MOVE TO VIRTUAL DISPLAY (x=\(Int(vdPos.x)), y=\(Int(vdPos.y)))")
    let moveResult = setWindowPosition(axWindow, vdPos)
    print("  AX set returned: \(moveResult)")
    Thread.sleep(forTimeInterval: 0.5)
    if let movedPos = getWindowPosition(axWindow) {
        print("  Actual position: (\(Int(movedPos.x)), \(Int(movedPos.y)))")
        if abs(movedPos.x - vdPos.x) < 10 {
            print("  Window is on the virtual display!")
        } else {
            print("  WARNING: Position was clamped - window may not be on virtual display")
        }
    }
    Thread.sleep(forTimeInterval: 0.5)
    let vdFPS = measureFPS(counter: capturer.frameCounter, duration: testDuration)
    print("  Result: \(String(format: "%.1f", vdFPS)) fps\n")

    // Restore
    print("Phase 3: RESTORE to original position")
    _ = setWindowPosition(axWindow, originalPos)
    raiseWindow(axWindow)
    Thread.sleep(forTimeInterval: 0.5)
    if let restoredPos = getWindowPosition(axWindow) {
        print("  Position: (\(Int(restoredPos.x)), \(Int(restoredPos.y)))")
    }
    let restoredFPS = measureFPS(counter: capturer.frameCounter, duration: testDuration)
    print("  Result: \(String(format: "%.1f", restoredFPS)) fps\n")

    // Summary
    print("=== RESULT ===")
    print("  Baseline:          \(String(format: "%.1f", baselineFPS)) fps")
    print("  On virtual display:\(String(format: " %.1f", vdFPS)) fps")
    print("  Restored:          \(String(format: "%.1f", restoredFPS)) fps")
    let verdict = vdFPS > 1.0 ? "PASS - capture continues on virtual display" : "FAIL - capture stopped"
    print("  Verdict:           \(verdict)")

    await capturer.stop()

    // Keep vDisplay alive until we're done
    _ = vDisplay
    print("\nDone. Virtual display will be removed on exit.")
}

// MARK: - Hold Mode (create virtual display for inspection)

func runHoldMode() {
    print("\n=== Virtual Display Hold Mode ===")
    print("Creating a tall virtual display for multi-window stacking...\n")

    // Tall display: 1920 wide, 10800 tall (fits ~10 windows stacked vertically)
    let vWidth: UInt = 1920
    let vHeight: UInt = 10800

    let desc = CGVirtualDisplayDescriptor()
    desc.setDispatchQueue(DispatchQueue.main)
    desc.terminationHandler = { _, _ in
        print("  Virtual display terminated")
    }
    desc.name = "Beam Hidden Display"
    desc.maxPixelsWide = UInt32(vWidth)
    desc.maxPixelsHigh = UInt32(vHeight)
    desc.sizeInMillimeters = CGSize(width: 600, height: 3400)
    desc.productID = 0xBEA0
    desc.vendorID = 0xBEA0
    desc.serialNum = 0x0001

    guard let vDisplay = CGVirtualDisplay(descriptor: desc) else {
        print("ERROR: Failed to create virtual display")
        return
    }
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 0
    settings.modes = [
        CGVirtualDisplayMode(width: vWidth, height: vHeight, refreshRate: 60)
    ]
    let applied = vDisplay.apply(settings)
    let displayID = vDisplay.displayID
    print("  Created: displayID=\(displayID), \(vWidth)x\(vHeight), applied=\(applied)")

    Thread.sleep(forTimeInterval: 0.5)

    // Show all displays
    var displayCount: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &displayCount)
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    CGGetActiveDisplayList(displayCount, &displays, &displayCount)
    print("  Active displays (\(displayCount)):")
    for d in displays {
        let b = CGDisplayBounds(d)
        let isMain = CGDisplayIsMain(d) != 0
        let isVirtual = d == displayID
        print("    Display \(d): origin=(\(Int(b.origin.x)),\(Int(b.origin.y))) size=\(Int(b.width))x\(Int(b.height))\(isMain ? " [MAIN]" : "")\(isVirtual ? " [VIRTUAL]" : "")")
    }

    // Position at bottom-left corner with minimal shared edge
    let mainBounds = CGDisplayBounds(CGMainDisplayID())
    let belowY = Int32(mainBounds.origin.y + mainBounds.height)
    let cornerX = Int32(-Int32(vWidth) + 1)
    print("\n  Positioning at bottom-left corner (\(cornerX), \(belowY))...")
    var config: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&config)
    CGConfigureDisplayOrigin(config, displayID, cornerX, belowY)
    let result = CGCompleteDisplayConfiguration(config, .forSession)
    Thread.sleep(forTimeInterval: 0.5)
    let b = CGDisplayBounds(displayID)
    print("  Result: \(result.rawValue), actual: (\(Int(b.origin.x)),\(Int(b.origin.y))) \(Int(b.width))x\(Int(b.height))")

    // Test live resize: can we change the mode without recreating?
    print("\n  Testing live resize via applySettings...")
    let smallSettings = CGVirtualDisplaySettings()
    smallSettings.hiDPI = 0
    smallSettings.modes = [
        CGVirtualDisplayMode(width: 1920, height: 5400, refreshRate: 60)
    ]
    let resizeApplied = vDisplay.apply(smallSettings)
    Thread.sleep(forTimeInterval: 0.5)
    let b2 = CGDisplayBounds(displayID)
    print("  Resize to 1920x5400: applied=\(resizeApplied), actual: \(Int(b2.width))x\(Int(b2.height))")

    // Resize back to tall
    let tallAgain = vDisplay.apply(settings)
    Thread.sleep(forTimeInterval: 0.5)
    let b3 = CGDisplayBounds(displayID)
    print("  Resize back to \(vWidth)x\(vHeight): applied=\(tallAgain), actual: \(Int(b3.width))x\(Int(b3.height))")

    print("\n  Virtual display is live. Open System Settings > Displays to inspect.")
    print("  Press Ctrl+C or wait 60 seconds to remove.\n")

    for i in stride(from: 60, through: 1, by: -10) {
        print("  \(i) seconds remaining...")
        Thread.sleep(forTimeInterval: min(Double(i), 10.0))
    }

    print("\n  Removing virtual display...")
    _ = vDisplay
    print("Done.")
}

// MARK: - Entry Point

var retainer: [AnyObject] = []

DispatchQueue.global().async {
    Task {
        do {
            let args = CommandLine.arguments
            print("=== Beam Window Hiding Spike ===\n")

            if args.contains("--list") {
                let windows = try await listWindows()
                for (i, w) in windows.enumerated() {
                    let appName = w.owningApplication?.applicationName ?? "?"
                    let title = w.title ?? "Untitled"
                    let size = "\(Int(w.frame.width))x\(Int(w.frame.height))"
                    print("[\(i)] \(appName) - \(title) (\(size))")
                }
                exit(0)
            }

            if args.contains("--hold") {
                runHoldMode()
                exit(0)
            }

            // Get window index from args
            var windowIdx = 0
            for flag in ["--test", "--offscreen", "--vdisplay"] {
                if let idx = args.firstIndex(of: flag), idx + 1 < args.count, let n = Int(args[idx + 1]) {
                    windowIdx = n
                    break
                }
            }

            let windows = try await listWindows()
            guard windowIdx >= 0 && windowIdx < windows.count else {
                print("Window index \(windowIdx) out of range (0..\(windows.count - 1))")
                exit(1)
            }

            if args.contains("--vdisplay") {
                try await runVirtualDisplayTest(window: windows[windowIdx])
            } else if args.contains("--offscreen") {
                try await runOffscreenOnly(window: windows[windowIdx])
            } else {
                try await runTests(window: windows[windowIdx])
            }
            exit(0)

        } catch let error as NSError where error.code == -3801 {
            print("\nScreen Recording permission required.")
            exit(1)
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}

signal(SIGINT) { _ in
    print("\nInterrupted.")
    exit(0)
}

app.run()
