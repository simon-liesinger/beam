import Foundation
import CoreGraphics
import AppKit
import CVirtualDisplay

/// Hides windows by moving them onto a CGVirtualDisplay positioned at the
/// bottom-left corner of the display arrangement. ScreenCaptureKit continues
/// capturing at full fps because the window is still "visible" on a real display.
///
/// Windows are stacked vertically to avoid occlusion (which kills capture).
/// The virtual display is created `.forSession` so it auto-removes on app exit.
class WindowHider {

    private var virtualDisplay: CGVirtualDisplay?
    private(set) var displayID: CGDirectDisplayID = 0
    private var displayBounds: CGRect = .zero

    /// AXUIElement → original position, for restoring on unhide
    private var hiddenWindows: [(element: AXUIElement, originalPosition: CGPoint)] = []

    private let displayWidth: UInt = 1920
    private var displayHeight: UInt = 1080  // grows on demand

    // MARK: - Create / Destroy Virtual Display

    func createDisplay() -> Bool {
        let desc = CGVirtualDisplayDescriptor()
        desc.setDispatchQueue(DispatchQueue.main)
        desc.terminationHandler = { _, _ in
            print("WindowHider: virtual display terminated")
        }
        desc.name = "Beam Hidden Display"
        desc.maxPixelsWide = UInt32(displayWidth)
        desc.maxPixelsHigh = UInt32(10800)  // max: supports many stacked windows
        desc.sizeInMillimeters = CGSize(width: 600, height: 340)
        desc.productID = 0xBEA0
        desc.vendorID = 0xBEA0
        desc.serialNum = 0x0001

        guard let vd = CGVirtualDisplay(descriptor: desc) else {
            print("WindowHider: failed to create virtual display")
            return false
        }
        virtualDisplay = vd

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [
            CGVirtualDisplayMode(width: displayWidth, height: displayHeight, refreshRate: 60)
        ]
        guard vd.apply(settings) else {
            print("WindowHider: failed to apply display settings")
            virtualDisplay = nil
            return false
        }

        displayID = vd.displayID
        positionAtBottomLeft()

        print("WindowHider: created display \(displayID) at \(displayBounds)")
        return true
    }

    func destroyDisplay() {
        // Restore all hidden windows first
        restoreAll()
        virtualDisplay = nil
        displayID = 0
        displayBounds = .zero
    }

    // MARK: - Hide / Restore

    /// Move a window onto the virtual display. Returns the AXUIElement for later restore.
    @discardableResult
    func hide(pid: pid_t, windowTitle: String? = nil) -> AXUIElement? {
        guard displayID != 0 else {
            print("WindowHider: no virtual display created")
            return nil
        }

        guard let axWindow = findAXWindow(pid: pid, title: windowTitle) else {
            print("WindowHider: no AX window found for PID \(pid)")
            return nil
        }

        guard let originalPos = getPosition(axWindow) else { return nil }

        // Stack vertically: each new window goes below the last
        let yOffset = hiddenWindows.reduce(CGFloat(0)) { total, entry in
            let size = getSize(entry.element)
            return total + (size?.height ?? 1080) + 50  // 50px gap to avoid occlusion
        }

        // Grow virtual display if needed
        let windowSize = getSize(axWindow)
        let neededHeight = UInt(yOffset + (windowSize?.height ?? 1080) + 100)
        if neededHeight > displayHeight {
            resizeDisplay(height: neededHeight)
        }

        let targetPos = CGPoint(x: displayBounds.origin.x + 50,
                                 y: displayBounds.origin.y + yOffset + 50)
        setPosition(axWindow, targetPos)

        hiddenWindows.append((element: axWindow, originalPosition: originalPos))
        print("WindowHider: hid window at (\(Int(targetPos.x)), \(Int(targetPos.y)))")
        return axWindow
    }

    /// Restore a specific window to its original position.
    func restore(_ axWindow: AXUIElement) {
        guard let idx = hiddenWindows.firstIndex(where: { $0.element === axWindow }) else { return }
        let entry = hiddenWindows.remove(at: idx)
        setPosition(entry.element, entry.originalPosition)
        raiseWindow(entry.element)
        print("WindowHider: restored window to (\(Int(entry.originalPosition.x)), \(Int(entry.originalPosition.y)))")
    }

    /// Restore all hidden windows.
    func restoreAll() {
        for entry in hiddenWindows.reversed() {
            setPosition(entry.element, entry.originalPosition)
            raiseWindow(entry.element)
        }
        hiddenWindows.removeAll()
    }

    /// The frame of the AX window on the virtual display (for input coordinate translation).
    func currentFrame(of axWindow: AXUIElement) -> CGRect? {
        guard let pos = getPosition(axWindow), let size = getSize(axWindow) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    // MARK: - Private

    private func positionAtBottomLeft() {
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let cornerX = Int32(-Int32(displayWidth) + 1)  // 1px overlap with main display's left edge
        let belowY = Int32(mainBounds.origin.y + mainBounds.height)

        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayOrigin(config, displayID, cornerX, belowY)
        CGCompleteDisplayConfiguration(config, .forSession)

        Thread.sleep(forTimeInterval: 0.3)
        displayBounds = CGDisplayBounds(displayID)
    }

    private func resizeDisplay(height: UInt) {
        displayHeight = height
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [
            CGVirtualDisplayMode(width: displayWidth, height: displayHeight, refreshRate: 60)
        ]
        virtualDisplay?.apply(settings)
        Thread.sleep(forTimeInterval: 0.2)
        displayBounds = CGDisplayBounds(displayID)
    }

    // MARK: - AXUIElement helpers

    private func findAXWindow(pid: pid_t, title: String?) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }

        if let title {
            for win in windows {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
                if let winTitle = titleRef as? String, winTitle.contains(title) {
                    return win
                }
            }
        }
        return windows.first
    }

    private func getPosition(_ element: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref) == .success,
              let val = ref else { return nil }
        var pt = CGPoint.zero
        AXValueGetValue(val as! AXValue, .cgPoint, &pt)
        return pt
    }

    @discardableResult
    private func setPosition(_ element: AXUIElement, _ point: CGPoint) -> Bool {
        var p = point
        guard let val = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, val) == .success
    }

    private func getSize(_ element: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success,
              let val = ref else { return nil }
        var size = CGSize.zero
        AXValueGetValue(val as! AXValue, .cgSize, &size)
        return size
    }

    private func raiseWindow(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
}
