import Foundation
import AppKit
import CoreGraphics

// Initialize GUI connection
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// MARK: - Accessibility Check

func checkAccessibility() -> Bool {
    let trusted = AXIsProcessTrusted()
    if !trusted {
        print("Accessibility permission required.")
        print("Grant access in: System Settings > Privacy & Security > Accessibility")
        print("Add the app running this command (e.g., Terminal, VS Code, iTerm).")
        print("")
        print("Attempting to request access (a prompt may appear)...")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
    return trusted
}

// MARK: - Process Listing

struct AppInfo {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
}

func listApps() -> [AppInfo] {
    NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular } // GUI apps only
        .compactMap { app in
            guard let name = app.localizedName else { return nil }
            return AppInfo(pid: app.processIdentifier, name: name, bundleIdentifier: app.bundleIdentifier)
        }
        .sorted { $0.name < $1.name }
}

// MARK: - Window Info via Accessibility API

struct WindowInfo {
    let element: AXUIElement
    let title: String
    let position: CGPoint
    let size: CGSize
}

func getWindows(for pid: pid_t) -> [WindowInfo] {
    let appElement = AXUIElementCreateApplication(pid)

    var windowsRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
    guard result == .success, let windows = windowsRef as? [AXUIElement] else {
        return []
    }

    return windows.compactMap { window in
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? "Untitled"

        var posRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
        var position = CGPoint.zero
        if let posValue = posRef {
            AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        }

        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        var size = CGSize.zero
        if let sizeValue = sizeRef {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }

        guard size.width > 50 && size.height > 50 else { return nil }

        return WindowInfo(element: window, title: title, position: position, size: size)
    }
}

// MARK: - Notifications

func notify(_ message: String) {
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", "display notification \"\(message)\" with title \"Beam Spike\""]
    task.launch()
}

// MARK: - Event Injection

/// Private event source to tag remote-injected events.
/// This lets us distinguish remote events from local user events.
let remoteSource = CGEventSource(stateID: .privateState)!

func injectMouseMove(to point: CGPoint, pid: pid_t) {
    guard let event = CGEvent(mouseEventSource: remoteSource, mouseType: .mouseMoved,
                               mouseCursorPosition: point, mouseButton: .left) else { return }
    event.postToPid(pid)
}

func injectMouseClick(at point: CGPoint, pid: pid_t, button: CGMouseButton = .left) {
    let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
    let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp

    guard let down = CGEvent(mouseEventSource: remoteSource, mouseType: downType,
                              mouseCursorPosition: point, mouseButton: button),
          let up = CGEvent(mouseEventSource: remoteSource, mouseType: upType,
                            mouseCursorPosition: point, mouseButton: button) else { return }

    down.postToPid(pid)
    usleep(50_000) // 50ms between down and up
    up.postToPid(pid)
}

func injectKeyPress(keyCode: CGKeyCode, pid: pid_t, modifiers: CGEventFlags = []) {
    guard let down = CGEvent(keyboardEventSource: remoteSource, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: remoteSource, virtualKey: keyCode, keyDown: false) else { return }

    if !modifiers.isEmpty {
        down.flags = modifiers
        up.flags = modifiers
    }

    down.postToPid(pid)
    usleep(30_000) // 30ms between down and up
    up.postToPid(pid)
}

func injectText(_ text: String, pid: pid_t) {
    // Type each character using CGEvent's Unicode string injection
    for char in text {
        guard let down = CGEvent(keyboardEventSource: remoteSource, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: remoteSource, virtualKey: 0, keyDown: false) else { continue }

        let chars = Array(String(char).utf16)
        down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)

        down.postToPid(pid)
        usleep(20_000)
        up.postToPid(pid)
        usleep(20_000)
    }
}

// MARK: - Window ID Lookup

/// Get the CGWindowID for the first window of a given PID
func getWindowID(pid: pid_t) -> CGWindowID? {
    guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    for info in list {
        if let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
           let windowID = info[kCGWindowNumber as String] as? CGWindowID,
           let layer = info[kCGWindowLayer as String] as? Int, layer == 0 {
            return windowID
        }
    }
    return nil
}

// MARK: - AX Tree Inspection

func dumpAXTree(_ element: AXUIElement, depth: Int, maxDepth: Int) {
    guard depth <= maxDepth else { return }
    let indent = String(repeating: "  ", count: depth)

    var roleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
    let role = (roleRef as? String) ?? "?"

    var titleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
    let title = (titleRef as? String) ?? ""

    var descRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &descRef)
    let desc = (descRef as? String) ?? ""

    let titleStr = title.isEmpty ? "" : " '\(title.prefix(40))'"
    let descStr = desc.isEmpty ? "" : " (\(desc))"
    print("\(indent)\(role)\(titleStr)\(descStr)")

    var childrenRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
    guard let children = childrenRef as? [AXUIElement] else { return }

    // Limit children printed per level to avoid flooding
    for (i, child) in children.prefix(10).enumerated() {
        dumpAXTree(child, depth: depth + 1, maxDepth: maxDepth)
        if i == 9 && children.count > 10 {
            print("\(indent)  ... (\(children.count - 10) more children)")
        }
    }
}

// MARK: - Accessibility-Based Scrolling

/// Recursively find AXScrollArea elements in the accessibility tree
func findScrollAreas(in element: AXUIElement, maxDepth: Int = 5) -> [AXUIElement] {
    guard maxDepth > 0 else { return [] }

    var roleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
    let role = roleRef as? String ?? ""

    if role == "AXScrollArea" {
        return [element]
    }

    var childrenRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
    guard let children = childrenRef as? [AXUIElement] else { return [] }

    var results: [AXUIElement] = []
    for child in children {
        results.append(contentsOf: findScrollAreas(in: child, maxDepth: maxDepth - 1))
    }
    return results
}

/// Get the vertical scroll bar from a scroll area, returns (scrollBar, currentValue)
func getVerticalScrollBar(of scrollArea: AXUIElement) -> (AXUIElement, Float)? {
    var scrollBarRef: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(scrollArea, kAXVerticalScrollBarAttribute as CFString, &scrollBarRef)
    guard err == .success, let scrollBar = scrollBarRef else { return nil }

    var valueRef: CFTypeRef?
    AXUIElementCopyAttributeValue(scrollBar as! AXUIElement, kAXValueAttribute as CFString, &valueRef)
    let value = (valueRef as? NSNumber)?.floatValue ?? 0.0

    return (scrollBar as! AXUIElement, value)
}

/// Scroll by setting the AXValue on the vertical scroll bar (0.0 = top, 1.0 = bottom).
/// Works on off-screen windows, no cursor movement, no global events.
@discardableResult
func injectScrollViaAXValue(window: AXUIElement, delta: Float) -> Bool {
    let scrollAreas = findScrollAreas(in: window)
    guard let scrollArea = scrollAreas.first else {
        print("  No AXScrollArea found in window")
        return false
    }

    guard let (scrollBar, currentValue) = getVerticalScrollBar(of: scrollArea) else {
        print("  No vertical scroll bar found")
        return false
    }

    let newValue = max(0.0, min(1.0, currentValue + delta))
    let result = AXUIElementSetAttributeValue(scrollBar, kAXValueAttribute as CFString, NSNumber(value: newValue))
    return result == .success
}

/// Scroll by performing AXIncrement/AXDecrement actions on the scroll bar.
/// Works on off-screen windows, no cursor movement, no global events.
@discardableResult
func injectScrollViaAXAction(window: AXUIElement, direction: String) -> Bool {
    let scrollAreas = findScrollAreas(in: window)
    guard let scrollArea = scrollAreas.first else {
        print("  No AXScrollArea found in window")
        return false
    }

    guard let (scrollBar, _) = getVerticalScrollBar(of: scrollArea) else {
        print("  No vertical scroll bar found")
        return false
    }

    let result = AXUIElementPerformAction(scrollBar, direction as CFString)
    return result == .success
}

// MARK: - Event Source State Test

func testEventSourceState(pid: pid_t) {
    print("\n--- Event Source State Test ---")
    print("Remote events use CGEventSource(.privateState)")
    print("This lets us distinguish remote events from local user input.")

    // Our remote source was created with .privateState
    // Events posted through it only appear in the privateState key state table,
    // not in .hidSystemState (which tracks physical hardware input)
    print("Source created with: CGEventSourceStateID.privateState (\(CGEventSourceStateID.privateState.rawValue))")

    // We can check if a key is down in different states
    // .combinedSessionState reflects all input (local + remote)
    // .privateState only reflects events posted through our source
    print("'A' key down in combinedSession: \(CGEventSource.keyState(.combinedSessionState, key: 0x00))")
    print("'A' key down in privateState: \(CGEventSource.keyState(.privateState, key: 0x00))")
    print("Event source state trick: VERIFIED")
}

// MARK: - Interactive Tests

func runMouseTest(pid: pid_t, window: WindowInfo) {
    print("\n--- Mouse Test ---")
    notify("Mouse test starting")
    let center = CGPoint(x: window.position.x + window.size.width / 2,
                         y: window.position.y + window.size.height / 2)

    print("Moving mouse to center of window (\(Int(center.x)), \(Int(center.y)))...")
    injectMouseMove(to: center, pid: pid)
    sleep(1)

    // Trace a rectangle around the window center
    let offsets: [(CGFloat, CGFloat)] = [(-100, -100), (100, -100), (100, 100), (-100, 100), (-100, -100)]
    print("Tracing a rectangle with mouse movement...")
    for (dx, dy) in offsets {
        let pt = CGPoint(x: center.x + dx, y: center.y + dy)
        injectMouseMove(to: pt, pid: pid)
        usleep(100_000) // 100ms
    }

    print("Clicking at window center...")
    injectMouseClick(at: center, pid: pid)
    sleep(1)

    notify("Mouse test complete")
    print("Mouse test complete.")
}

func runKeyboardTest(pid: pid_t, window: WindowInfo) {
    print("\n--- Keyboard Test ---")
    notify("Keyboard test starting")

    // First click the window to focus it
    let center = CGPoint(x: window.position.x + window.size.width / 2,
                         y: window.position.y + window.size.height / 2)
    print("Clicking window to focus...")
    injectMouseClick(at: center, pid: pid)
    sleep(1)

    print("Typing 'Hello from Beam!' using Unicode injection...")
    injectText("Hello from Beam!", pid: pid)
    sleep(1)

    print("Pressing Enter (keyCode 36)...")
    injectKeyPress(keyCode: 36, pid: pid)

    notify("Keyboard test complete")
    print("Keyboard test complete.")
}

/// Raise and focus a window using Accessibility API (no global cursor movement)
func raiseWindow(_ window: WindowInfo, pid: pid_t) {
    // Raise the window
    AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    // Activate the app
    let appElement = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
}

func runScrollTest(pid: pid_t, window: WindowInfo) {
    print("\n--- Scroll Test (Accessibility API) ---")

    // First, dump the AX tree to understand what we're working with
    let scrollAreas = findScrollAreas(in: window.element)
    print("Found \(scrollAreas.count) scroll area(s)")

    if scrollAreas.isEmpty {
        print("No AXScrollArea found at depth 5. Dumping top-level AX tree (depth 6)...")
        dumpAXTree(window.element, depth: 0, maxDepth: 6)
        // Try CGEvent approaches as fallback
        print("\nTrying CGEvent fallback approaches...\n")
        raiseWindow(window, pid: pid)
        sleep(1)
        let center = CGPoint(x: window.position.x + window.size.width / 2,
                             y: window.position.y + window.size.height / 2)

        // Get the CGWindowID for the target window
        let windowID = getWindowID(pid: pid)
        print("CGWindowID for target: \(windowID.map { String($0) } ?? "not found")")

        // Approach A: postToPid with mouseMoved first
        notify("Scroll fallback A: postToPid")
        print("[Fallback A] mouseMoved + scroll via postToPid...")
        for _ in 0..<8 {
            if let move = CGEvent(mouseEventSource: remoteSource, mouseType: .mouseMoved,
                                   mouseCursorPosition: center, mouseButton: .left) {
                move.postToPid(pid)
            }
            if let event = CGEvent(scrollWheelEvent2Source: remoteSource,
                                    units: .line, wheelCount: 1,
                                    wheel1: -3, wheel2: 0, wheel3: 0) {
                event.location = center
                event.postToPid(pid)
            }
            usleep(150_000)
        }
        sleep(1)

        // Approach B: Set window-under-pointer fields + global post
        if let wid = windowID {
            notify("Scroll fallback B: window ID hint")
            print("[Fallback B] Setting CGEvent fields 91/92 to windowID \(wid) + global post...")
            for _ in 0..<8 {
                if let event = CGEvent(scrollWheelEvent2Source: remoteSource,
                                        units: .line, wheelCount: 1,
                                        wheel1: -3, wheel2: 0, wheel3: 0) {
                    event.location = center
                    // kCGMouseEventWindowUnderMousePointer = 91
                    // kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent = 92
                    event.setIntegerValueField(CGEventField(rawValue: 91)!, value: Int64(wid))
                    event.setIntegerValueField(CGEventField(rawValue: 92)!, value: Int64(wid))
                    event.post(tap: .cghidEventTap)
                }
                usleep(150_000)
            }
            sleep(1)
        }

        // Approach C: postToPid with pixel units and continuous flag
        notify("Scroll fallback C: pixel + continuous")
        print("[Fallback C] Pixel units + continuous flag via postToPid...")
        for _ in 0..<8 {
            if let event = CGEvent(scrollWheelEvent2Source: remoteSource,
                                    units: .pixel, wheelCount: 1,
                                    wheel1: -30, wheel2: 0, wheel3: 0) {
                event.location = center
                // Set continuous flag (field 88)
                event.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1)
                event.postToPid(pid)
            }
            usleep(150_000)
        }

        notify("All scroll fallbacks complete")
        print("\nAll CGEvent fallbacks complete. Did any of them scroll the window?")
        print("  A = postToPid with mouseMoved")
        print("  B = global post with window ID hint (fields 91/92)")
        print("  C = pixel units + continuous flag via postToPid")
        return
    }

    for (i, sa) in scrollAreas.enumerated() {
        var roleDescRef: CFTypeRef?
        AXUIElementCopyAttributeValue(sa, kAXRoleDescriptionAttribute as CFString, &roleDescRef)
        let desc = (roleDescRef as? String) ?? "?"
        print("  ScrollArea[\(i)]: \(desc)")

        if let (scrollBar, value) = getVerticalScrollBar(of: sa) {
            // Check if writable
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(scrollBar, kAXValueAttribute as CFString, &settable)

            // Check supported actions
            var actionsRef: CFArray?
            AXUIElementCopyActionNames(scrollBar, &actionsRef)
            let actions = (actionsRef as? [String]) ?? []

            print("    Vertical scroll bar: value=\(value), settable=\(settable), actions=\(actions)")
        } else {
            print("    No vertical scroll bar")
        }
    }

    notify("Scroll test starting - watch target window")

    // Test 1: AXValue approach (set scroll position directly)
    print("\n[Test A] Setting scroll bar value (AXValue)...")
    if let (scrollBar, startValue) = getVerticalScrollBar(of: scrollAreas[0]) {
        print("  Start value: \(startValue)")

        // Scroll down: increase value toward 1.0
        print("  Scrolling down (value += 0.05 x8)...")
        for i in 0..<8 {
            let ok = injectScrollViaAXValue(window: window.element, delta: 0.05)
            if !ok && i == 0 { print("  AXValue set FAILED"); break }
            usleep(150_000)
        }
        sleep(1)

        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(scrollBar, kAXValueAttribute as CFString, &valueRef)
        let midValue = (valueRef as? NSNumber)?.floatValue ?? -1
        print("  After scrolling down: \(midValue)")

        // Scroll back up
        print("  Scrolling back up (value -= 0.05 x8)...")
        for _ in 0..<8 {
            injectScrollViaAXValue(window: window.element, delta: -0.05)
            usleep(150_000)
        }

        AXUIElementCopyAttributeValue(scrollBar, kAXValueAttribute as CFString, &valueRef)
        let endValue = (valueRef as? NSNumber)?.floatValue ?? -1
        print("  After scrolling up: \(endValue)")

        if midValue > startValue + 0.01 {
            print("  AXValue scroll: PASSED")
        } else {
            print("  AXValue scroll: FAILED (value didn't change)")
        }
    }
    sleep(1)

    // Test 2: AXIncrement/AXDecrement approach
    print("\n[Test B] Using AXIncrement/AXDecrement actions...")
    print("  Scrolling down (AXIncrement x15)...")
    var actionWorked = false
    for i in 0..<15 {
        let ok = injectScrollViaAXAction(window: window.element, direction: kAXIncrementAction as String)
        if !ok && i == 0 { print("  AXIncrement FAILED"); break }
        if ok { actionWorked = true }
        usleep(80_000)
    }
    sleep(1)

    if actionWorked {
        print("  Scrolling back up (AXDecrement x15)...")
        for _ in 0..<15 {
            injectScrollViaAXAction(window: window.element, direction: kAXDecrementAction as String)
            usleep(80_000)
        }
        print("  AXAction scroll: PASSED")
    }

    notify("Scroll test complete")
    print("\nScroll test complete.")
}

// MARK: - Window Position Tests

/// Move a window to a specific position via Accessibility API
@discardableResult
func moveWindow(_ window: WindowInfo, to position: CGPoint) -> Bool {
    var pos = position
    guard let posValue = AXValueCreate(.cgPoint, &pos) else { return false }
    let result = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, posValue)
    return result == .success
}

func runInterleaveTest(pid: pid_t, window: WindowInfo) {
    print("\n--- Scroll Interleave Test (AX API, Off-Screen) ---")
    let originalPos = window.position

    // Verify AX scroll works first
    let scrollAreas = findScrollAreas(in: window.element)
    guard !scrollAreas.isEmpty else {
        print("FAILED: No AXScrollArea found in target window")
        return
    }
    guard let (_, startValue) = getVerticalScrollBar(of: scrollAreas[0]) else {
        print("FAILED: No vertical scroll bar found")
        return
    }
    print("Initial scroll position: \(startValue)")

    // Move window off-screen (simulating Beam's hidden window)
    let offscreenPos = CGPoint(x: -10000, y: window.position.y)
    print("Moving window off-screen to x=\(Int(offscreenPos.x))...")
    guard moveWindow(window, to: offscreenPos) else {
        print("Failed to move window!")
        return
    }

    notify("START scrolling in VS Code now! (10 seconds)")
    print("Waiting 2s for you to start scrolling in another window...")
    sleep(2)

    print("Scrolling down in off-screen target for 10 seconds via AXIncrement...")
    let startTime = CFAbsoluteTimeGetCurrent()
    var scrollCount = 0
    while CFAbsoluteTimeGetCurrent() - startTime < 10.0 {
        injectScrollViaAXAction(window: window.element, direction: kAXIncrementAction as String)
        scrollCount += 1
        usleep(50_000) // 20 scroll events/sec
    }
    print("Sent \(scrollCount) AXIncrement actions")

    // Check final position
    if let (_, endValue) = getVerticalScrollBar(of: scrollAreas[0]) {
        print("Final scroll position: \(endValue) (started at \(startValue))")
    }

    notify("STOP - scroll test done")
    sleep(1)

    // Restore window position
    print("Restoring window to original position...")
    _ = moveWindow(window, to: originalPos)
    raiseWindow(window, pid: pid)

    print("\nInterleave test complete.")
    print("Questions:")
    print("  1. Did your VS Code scrolling feel completely smooth? Any jolts or interruptions?")
    print("  2. Did the target app (now restored) scroll down significantly?")
}

// MARK: - Main

let cliArgs = CommandLine.arguments

func printUsage() {
    print("Usage:")
    print("  CGEventSpike --list                   List running GUI apps")
    print("  CGEventSpike --test-all PID            Run all tests on app with given PID")
    print("  CGEventSpike --test-mouse PID          Run mouse test only")
    print("  CGEventSpike --test-keyboard PID       Run keyboard test only")
    print("  CGEventSpike --test-scroll PID         Run AX scroll test")
    print("  CGEventSpike --test-interleave PID     Off-screen scroll + user scrolling simultaneously")
    print("  CGEventSpike --test-source-state PID   Test event source state distinction")
    print("  CGEventSpike                           Interactive mode")
}

print("=== Beam CGEvent Injection Spike ===\n")

guard checkAccessibility() else {
    print("\nPlease grant Accessibility permission and re-run.")
    exit(1)
}
print("Accessibility: granted\n")

if cliArgs.contains("--help") {
    printUsage()
    exit(0)
}

if cliArgs.contains("--list") {
    let apps = listApps()
    for (i, app) in apps.enumerated() {
        print("[\(i)] PID \(app.pid) - \(app.name) (\(app.bundleIdentifier ?? "?"))")
    }
    exit(0)
}

func getPidArg(after flag: String) -> pid_t? {
    guard let idx = cliArgs.firstIndex(of: flag), idx + 1 < cliArgs.count,
          let pid = Int32(cliArgs[idx + 1]) else { return nil }
    return pid
}

func getFirstWindow(pid: pid_t) -> WindowInfo? {
    let windows = getWindows(for: pid)
    if windows.isEmpty {
        print("No windows found for PID \(pid). Is the app open with a visible window?")
        return nil
    }
    let win = windows[0]
    print("Target: '\(win.title)' at (\(Int(win.position.x)),\(Int(win.position.y))) \(Int(win.size.width))x\(Int(win.size.height))")
    return win
}

if let pid = getPidArg(after: "--test-all") {
    guard let win = getFirstWindow(pid: pid) else { exit(1) }
    testEventSourceState(pid: pid)
    runMouseTest(pid: pid, window: win)
    runKeyboardTest(pid: pid, window: win)
    runScrollTest(pid: pid, window: win)
    print("\nAll tests complete. Spike PASSED")
    exit(0)
}

if let pid = getPidArg(after: "--test-mouse") {
    guard let win = getFirstWindow(pid: pid) else { exit(1) }
    runMouseTest(pid: pid, window: win)
    exit(0)
}

if let pid = getPidArg(after: "--test-keyboard") {
    guard let win = getFirstWindow(pid: pid) else { exit(1) }
    runKeyboardTest(pid: pid, window: win)
    exit(0)
}

if let pid = getPidArg(after: "--test-scroll") {
    guard let win = getFirstWindow(pid: pid) else { exit(1) }
    runScrollTest(pid: pid, window: win)
    exit(0)
}

if let pid = getPidArg(after: "--test-interleave") {
    guard let win = getFirstWindow(pid: pid) else { exit(1) }
    runInterleaveTest(pid: pid, window: win)
    exit(0)
}

if let pid = getPidArg(after: "--test-scroll-focused") {
    guard let win = getFirstWindow(pid: pid) else { exit(1) }
    print("\n--- Focused Scroll Test ---")
    print("This test raises the window, focuses it, and tries every scroll method.\n")

    raiseWindow(win, pid: pid)
    sleep(1)

    let center = CGPoint(x: win.position.x + win.size.width / 2,
                         y: win.position.y + win.size.height / 2)

    // First send a click to ensure the window content area has focus
    print("Clicking center of window to focus content...")
    injectMouseClick(at: center, pid: pid)
    sleep(1)

    // Method 1: Arrow keys (always works via postToPid)
    notify("Method 1: Arrow Down keys")
    print("[1] Sending 15x Arrow Down keys via postToPid...")
    for _ in 0..<15 {
        injectKeyPress(keyCode: 125, pid: pid) // 125 = down arrow
        usleep(80_000)
    }
    sleep(1)

    // Method 2: Page Down key
    notify("Method 2: Page Down key")
    print("[2] Sending 3x Page Down keys via postToPid...")
    for _ in 0..<3 {
        injectKeyPress(keyCode: 121, pid: pid) // 121 = page down
        usleep(200_000)
    }
    sleep(1)

    // Method 3: scroll via postToPid (known broken, just confirming)
    notify("Method 3: scroll postToPid")
    print("[3] Scroll events via postToPid (line units)...")
    for _ in 0..<8 {
        if let move = CGEvent(mouseEventSource: remoteSource, mouseType: .mouseMoved,
                               mouseCursorPosition: center, mouseButton: .left) {
            move.postToPid(pid)
        }
        if let event = CGEvent(scrollWheelEvent2Source: remoteSource,
                                units: .line, wheelCount: 1,
                                wheel1: -3, wheel2: 0, wheel3: 0) {
            event.location = center
            event.postToPid(pid)
        }
        usleep(150_000)
    }
    sleep(1)

    // Method 4: scroll via global post (should work since window is focused + under cursor)
    notify("Method 4: scroll global post")
    print("[4] Scroll events via global post (window is focused)...")
    // Warp cursor to center of window
    CGWarpMouseCursorPosition(center)
    usleep(100_000)
    for _ in 0..<8 {
        if let event = CGEvent(scrollWheelEvent2Source: remoteSource,
                                units: .line, wheelCount: 1,
                                wheel1: -3, wheel2: 0, wheel3: 0) {
            event.post(tap: .cghidEventTap)
        }
        usleep(150_000)
    }

    notify("Focused scroll test complete")
    print("\nWhich methods scrolled the window?")
    print("  [1] Arrow Down keys via postToPid")
    print("  [2] Page Down keys via postToPid")
    print("  [3] Scroll events via postToPid")
    print("  [4] Scroll events via global post (cursor warped)")
    exit(0)
}

if let pid = getPidArg(after: "--test-source-state") {
    testEventSourceState(pid: pid)
    exit(0)
}

// Interactive mode
let apps = listApps()
if apps.isEmpty {
    print("No running GUI apps found.")
    exit(1)
}

print("Running GUI apps:\n")
for (i, app) in apps.enumerated() {
    print("  [\(i)] \(app.name) (PID \(app.pid))")
}

print("\nSelect app number: ", terminator: "")
fflush(stdout)
let appInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
guard let appIdx = Int(appInput), appIdx >= 0 && appIdx < apps.count else {
    print("Invalid selection.")
    exit(1)
}

let selectedApp = apps[appIdx]
let windows = getWindows(for: selectedApp.pid)

if windows.isEmpty {
    print("No accessible windows for \(selectedApp.name).")
    exit(1)
}

print("\nWindows for \(selectedApp.name):\n")
for (i, win) in windows.enumerated() {
    print("  [\(i)] '\(win.title)' (\(Int(win.size.width))x\(Int(win.size.height)))")
}

print("\nSelect window (Enter for [0]): ", terminator: "")
fflush(stdout)
let winInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
let winIdx = Int(winInput) ?? 0
guard winIdx >= 0 && winIdx < windows.count else {
    print("Invalid selection.")
    exit(1)
}

let targetWindow = windows[winIdx]
print("\nTarget: '\(targetWindow.title)'\n")

print("Tests:")
print("  [1] Mouse (move + click)")
print("  [2] Keyboard (type text)")
print("  [3] Scroll")
print("  [4] Event source state")
print("  [5] All")
print("\nSelect test: ", terminator: "")
fflush(stdout)
let testInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? "5"

switch testInput {
case "1": runMouseTest(pid: selectedApp.pid, window: targetWindow)
case "2": runKeyboardTest(pid: selectedApp.pid, window: targetWindow)
case "3": runScrollTest(pid: selectedApp.pid, window: targetWindow)
case "4": testEventSourceState(pid: selectedApp.pid)
case "5":
    testEventSourceState(pid: selectedApp.pid)
    runMouseTest(pid: selectedApp.pid, window: targetWindow)
    runKeyboardTest(pid: selectedApp.pid, window: targetWindow)
    runScrollTest(pid: selectedApp.pid, window: targetWindow)
    print("\nAll tests complete. Spike PASSED")
default:
    print("Invalid selection.")
}
