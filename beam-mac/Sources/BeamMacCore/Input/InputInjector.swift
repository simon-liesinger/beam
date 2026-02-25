import Foundation
import CoreGraphics
import AppKit

/// Injects mouse, keyboard, and scroll events into a target app.
/// Clicks use AXUIElement (no cursor movement) with CGEvent.post(.cghidEventTap) fallback.
/// Mouse moves use CGEvent.postToPid. Scroll uses CGEvent scroll wheel.
class InputInjector {

    private let pid: pid_t
    private let source: CGEventSource
    private var axWindow: AXUIElement?
    private var targetWindowID: CGWindowID = 0

    /// Buffered mouseDown — resolved on mouseUp (AX click) or mouseDrag (CGEvent).
    private var pendingMouseDown: (point: CGPoint, button: CGMouseButton, time: CFAbsoluteTime)?

    /// Set to true after AX clicks fail, so we skip AX and use CGEvent directly.
    private var axClicksFailed = false

    /// Called when AX click injection fails and we need the window visible for CGEvent fallback.
    var onNeedsCGEventFallback: (() -> Void)?

    init(pid: pid_t) {
        self.pid = pid
        self.source = CGEventSource(stateID: .privateState)!
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement], let first = windows.first {
            axWindow = first
        }
    }

    func setAXWindow(_ window: AXUIElement) {
        axWindow = window
    }

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

    /// On mouseUp: if we have a buffered mouseDown nearby, treat as click.
    /// Otherwise deliver mouseUp via CGEvent (end of drag).
    func mouseUp(at point: CGPoint, button: CGMouseButton = .left) {
        if let pending = pendingMouseDown,
           pending.button == button,
           hypot(point.x - pending.point.x, point.y - pending.point.y) < 10,
           CFAbsoluteTimeGetCurrent() - pending.time < 0.5 {
            // Simple click
            pendingMouseDown = nil
            if !axClicksFailed, performAXClick(at: point, button: button) {
                return
            }
            // AX failed — use CGEvent through HID tap (moves cursor but works)
            if !axClicksFailed {
                axClicksFailed = true
                print("InputInjector: AX clicks not supported, switching to CGEvent fallback")
                onNeedsCGEventFallback?()
            }
            deliverCGEventClick(at: point, button: button)
        } else {
            // End of drag
            pendingMouseDown = nil
            let type: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                       mouseCursorPosition: point, mouseButton: button) else { return }
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
    }

    func click(at point: CGPoint, button: CGMouseButton = .left) {
        if !axClicksFailed, performAXClick(at: point, button: button) { return }
        deliverCGEventClick(at: point, button: button)
    }

    /// On mouseDrag: flush any buffered mouseDown as CGEvent first, then deliver drag.
    func mouseDrag(to point: CGPoint) {
        if let pending = pendingMouseDown {
            pendingMouseDown = nil
            guard let downEvent = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                           mouseCursorPosition: pending.point, mouseButton: .left) else { return }
            downEvent.setIntegerValueField(.mouseEventClickState, value: 1)
            downEvent.post(tap: .cghidEventTap)
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                                   mouseCursorPosition: point, mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Accessibility Click

    /// Perform a click via AXUIElement — no cursor movement at all.
    private func performAXClick(at point: CGPoint, button: CGMouseButton) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(appElement, Float(point.x), Float(point.y), &elementRef) == .success,
              let element = elementRef else {
            return false
        }

        let action = button == .right
            ? kAXShowMenuAction as CFString
            : kAXPressAction as CFString

        return AXUIElementPerformAction(element, action) == .success
    }

    /// CGEvent fallback — posts through HID tap which moves cursor but always works.
    private func deliverCGEventClick(at point: CGPoint, button: CGMouseButton) {
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp

        guard let down = CGEvent(mouseEventSource: source, mouseType: downType,
                                  mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: source, mouseType: upType,
                                mouseCursorPosition: point, mouseButton: button) else { return }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        usleep(30_000)
        up.post(tap: .cghidEventTap)
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

    /// Scroll via CGEvent scroll wheel. Posts via postToPid (scroll doesn't move cursor).
    func scroll(deltaY: Double, precise: Bool) {
        let units: CGScrollEventUnit = precise ? .pixel : .line
        let amount = precise ? Int32(deltaY) : Int32(deltaY)
        guard amount != 0 else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: units,
                                   wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0) else { return }
        event.postToPid(pid)
    }

    // MARK: - Dispatch from normalized input event

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
            let dy = event["deltaY"] as? Double ?? (event["deltaY"] as? NSNumber)?.doubleValue ?? 0
            let precise = event["precise"] as? Bool ?? false
            scroll(deltaY: dy, precise: precise)

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
}
