import Foundation
import CoreGraphics
import AppKit

/// Injects mouse, keyboard, and scroll events into a target app.
/// Clicks use AXUIElement (no cursor movement). Mouse moves use CGEvent.postToPid.
/// Drags fall back to CGEvent with warp-and-restore.
/// Scroll uses AXUIElement scroll bar value (works off-screen), with Page Down fallback.
class InputInjector {

    private let pid: pid_t
    private let source: CGEventSource
    private var axWindow: AXUIElement?
    private var targetWindowID: CGWindowID = 0

    /// Buffered mouseDown — resolved on mouseUp (AX click) or mouseDrag (CGEvent).
    private var pendingMouseDown: (point: CGPoint, button: CGMouseButton, time: CFAbsoluteTime)?

    init(pid: pid_t) {
        self.pid = pid
        self.source = CGEventSource(stateID: .privateState)!
        // Cache AX handle for scroll injection
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement], let first = windows.first {
            axWindow = first
        }
    }

    /// Update the AX window reference (e.g. after window restore).
    func setAXWindow(_ window: AXUIElement) {
        axWindow = window
    }

    /// Set the target CGWindowID for event routing.
    func setTargetWindowID(_ windowID: CGWindowID) {
        targetWindowID = windowID
    }

    // MARK: - Mouse

    func mouseMove(to point: CGPoint, deltaX: Double = 0, deltaY: Double = 0) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                   mouseCursorPosition: point, mouseButton: .left) else { return }
        if deltaX != 0 || deltaY != 0 {
            event.setDoubleValueField(.mouseEventDeltaX, value: deltaX)
            event.setDoubleValueField(.mouseEventDeltaY, value: deltaY)
        }
        event.postToPid(pid)
    }

    /// Buffer mouseDown — we don't know yet if this is a click or drag start.
    func mouseDown(at point: CGPoint, button: CGMouseButton = .left) {
        pendingMouseDown = (point: point, button: button, time: CFAbsoluteTimeGetCurrent())
    }

    /// On mouseUp: if we have a buffered mouseDown nearby, treat as click (AX).
    /// Otherwise deliver mouseUp via CGEvent (end of drag).
    func mouseUp(at point: CGPoint, button: CGMouseButton = .left) {
        if let pending = pendingMouseDown,
           pending.button == button,
           hypot(point.x - pending.point.x, point.y - pending.point.y) < 10,
           CFAbsoluteTimeGetCurrent() - pending.time < 0.5 {
            // Simple click — use Accessibility API (no cursor movement)
            pendingMouseDown = nil
            if !performAXClick(at: point, button: button) {
                // AX failed — fall back to CGEvent warp-click
                deliverCGEventClick(at: point, button: button)
            }
        } else {
            // End of drag
            pendingMouseDown = nil
            let type: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                       mouseCursorPosition: point, mouseButton: button) else { return }
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            warpPostAndRestore(event)
        }
    }

    func click(at point: CGPoint, button: CGMouseButton = .left) {
        if !performAXClick(at: point, button: button) {
            deliverCGEventClick(at: point, button: button)
        }
    }

    /// On mouseDrag: flush any buffered mouseDown as CGEvent first, then deliver drag.
    func mouseDrag(to point: CGPoint) {
        if let pending = pendingMouseDown {
            pendingMouseDown = nil
            guard let downEvent = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                           mouseCursorPosition: pending.point, mouseButton: .left) else { return }
            downEvent.setIntegerValueField(.mouseEventClickState, value: 1)
            warpPostAndRestore(downEvent)
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                                   mouseCursorPosition: point, mouseButton: .left) else { return }
        warpPostAndRestore(event)
    }

    // MARK: - Accessibility Click

    /// Perform a click via AXUIElement — no cursor movement at all.
    /// Returns true if the action was successfully delivered.
    private func performAXClick(at point: CGPoint, button: CGMouseButton) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(appElement, Float(point.x), Float(point.y), &elementRef) == .success,
              let element = elementRef else {
            print("InputInjector: AX element not found at (\(Int(point.x)), \(Int(point.y)))")
            return false
        }

        let action = button == .right
            ? kAXShowMenuAction as CFString
            : kAXPressAction as CFString

        let result = AXUIElementPerformAction(element, action)
        if result == .success {
            print("InputInjector: AX press at (\(Int(point.x)), \(Int(point.y)))")
            return true
        } else {
            print("InputInjector: AX press failed (\(result.rawValue)) at (\(Int(point.x)), \(Int(point.y)))")
            return false
        }
    }

    /// CGEvent fallback for clicks when AX doesn't work.
    private func deliverCGEventClick(at point: CGPoint, button: CGMouseButton) {
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp

        guard let down = CGEvent(mouseEventSource: source, mouseType: downType,
                                  mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: source, mouseType: upType,
                                mouseCursorPosition: point, mouseButton: button) else { return }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        warpPostAndRestore(down)
        usleep(30_000)
        warpPostAndRestore(up)
    }

    /// Warp cursor to event position, deliver via postToPid, warp back.
    /// Used for drags and CGEvent fallback clicks.
    private func warpPostAndRestore(_ event: CGEvent) {
        let savedPos = CGEvent(source: nil)?.location ?? .zero
        CGWarpMouseCursorPosition(event.location)
        event.postToPid(pid)
        CGWarpMouseCursorPosition(savedPos)
    }

    // MARK: - Keyboard

    func keyDown(keyCode: CGKeyCode, modifiers: CGEventFlags = []) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else { return }
        if !modifiers.isEmpty { event.flags = modifiers }
        event.postToPid(pid)
    }

    func keyUp(keyCode: CGKeyCode, modifiers: CGEventFlags = []) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        if !modifiers.isEmpty { event.flags = modifiers }
        event.postToPid(pid)
    }

    func keyPress(keyCode: CGKeyCode, modifiers: CGEventFlags = []) {
        keyDown(keyCode: keyCode, modifiers: modifiers)
        usleep(20_000)
        keyUp(keyCode: keyCode, modifiers: modifiers)
    }

    func typeText(_ text: String) {
        for char in text {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            let utf16 = Array(String(char).utf16)
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.postToPid(pid)
            usleep(15_000)
            up.postToPid(pid)
            usleep(15_000)
        }
    }

    // MARK: - Scroll

    /// Scroll via AXScrollBar value (works on off-screen windows). delta > 0 = scroll down.
    /// Falls back to Page Down/Up keys if no scroll bar is found.
    func scroll(deltaY: Float) {
        guard let axWindow else {
            scrollViaKeys(deltaY: deltaY)
            return
        }

        if let scrollBar = findVerticalScrollBar(in: axWindow) {
            var valueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(scrollBar, kAXValueAttribute as CFString, &valueRef)
            let current = (valueRef as? NSNumber)?.floatValue ?? 0
            let newValue = max(0, min(1, current + deltaY))
            AXUIElementSetAttributeValue(scrollBar, kAXValueAttribute as CFString, NSNumber(value: newValue))
        } else {
            scrollViaKeys(deltaY: deltaY)
        }
    }

    // MARK: - Dispatch from normalized input event

    /// Apply a remote input event dict (from TCPControlChannel) to the target window.
    /// `windowFrame` is the target window's current frame in screen coords.
    func apply(event: [String: Any], windowFrame: CGRect) {
        guard let type = event["type"] as? String else { return }

        switch type {
        case "mouseMove":
            guard let pt = denormalize(event, in: windowFrame) else { return }
            let dx = event["deltaX"] as? Double ?? 0
            let dy = event["deltaY"] as? Double ?? 0
            mouseMove(to: pt, deltaX: dx, deltaY: dy)

        case "mouseDown":
            guard let pt = denormalize(event, in: windowFrame) else { return }
            let btn = (event["button"] as? String) == "right" ? CGMouseButton.right : .left
            mouseDown(at: pt, button: btn)

        case "mouseUp":
            guard let pt = denormalize(event, in: windowFrame) else { return }
            let btn = (event["button"] as? String) == "right" ? CGMouseButton.right : .left
            mouseUp(at: pt, button: btn)

        case "mouseDrag":
            guard let pt = denormalize(event, in: windowFrame) else { return }
            mouseDrag(to: pt)

        case "keyDown":
            guard let code = event["keyCode"] as? Int else { return }
            let mods = modifierFlags(from: event)
            keyDown(keyCode: CGKeyCode(code), modifiers: mods)

        case "keyUp":
            guard let code = event["keyCode"] as? Int else { return }
            let mods = modifierFlags(from: event)
            keyUp(keyCode: CGKeyCode(code), modifiers: mods)

        case "text":
            guard let text = event["text"] as? String else { return }
            typeText(text)

        case "scroll":
            let dy = (event["deltaY"] as? NSNumber)?.floatValue ?? 0
            scroll(deltaY: dy)

        default:
            break
        }
    }

    // MARK: - Private helpers

    private func denormalize(_ event: [String: Any], in frame: CGRect) -> CGPoint? {
        guard let nx = event["x"] as? Double, let ny = event["y"] as? Double else { return nil }
        return CGPoint(x: frame.origin.x + CGFloat(nx) * frame.width,
                       y: frame.origin.y + CGFloat(ny) * frame.height)
    }

    private func modifierFlags(from event: [String: Any]) -> CGEventFlags {
        var flags = CGEventFlags()
        if event["shift"] as? Bool == true   { flags.insert(.maskShift) }
        if event["control"] as? Bool == true { flags.insert(.maskControl) }
        if event["option"] as? Bool == true  { flags.insert(.maskAlternate) }
        if event["command"] as? Bool == true { flags.insert(.maskCommand) }
        return flags
    }

    private func scrollViaKeys(deltaY: Float) {
        let keyCode: CGKeyCode = deltaY > 0 ? 121 : 116
        keyPress(keyCode: keyCode)
    }

    private func findVerticalScrollBar(in element: AXUIElement) -> AXUIElement? {
        if let scrollArea = findScrollArea(in: element, depth: 5) {
            var scrollBarRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(scrollArea, kAXVerticalScrollBarAttribute as CFString,
                                              &scrollBarRef) == .success {
                return (scrollBarRef as! AXUIElement)
            }
        }
        return nil
    }

    private func findScrollArea(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth > 0 else { return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if (roleRef as? String) == "AXScrollArea" { return element }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findScrollArea(in: child, depth: depth - 1) { return found }
        }
        return nil
    }
}
