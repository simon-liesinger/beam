import Foundation
import AppKit

/// Captures NSEvents on the receiver's stream window and serializes them
/// as normalized (0–1) coordinate JSON messages for the TCP control channel.
/// Installed as a local event monitor on the stream window's contentView.
class RemoteInputHandler {

    private var localMonitor: Any?
    private var flagsMonitor: Any?
    private weak var targetView: NSView?

    /// Called with a serialized input event dict ready to send over TCP.
    var onInputEvent: (([String: Any]) -> Void)?

    // MARK: - Start / Stop

    func attach(to view: NSView) {
        targetView = view
        let eventMask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .leftMouseDragged, .rightMouseDragged, .scrollWheel,
            .keyDown, .keyUp
        ]

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleEvent(event)
            return event
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    func detach() {
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        localMonitor = nil
        flagsMonitor = nil
        targetView = nil
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: NSEvent) {
        guard let view = targetView, event.window == view.window else { return }

        switch event.type {
        case .mouseMoved:
            sendMouse("mouseMove", event: event, view: view)

        case .leftMouseDown:
            sendMouse("mouseDown", event: event, view: view, button: "left")

        case .leftMouseUp:
            sendMouse("mouseUp", event: event, view: view, button: "left")

        case .rightMouseDown:
            sendMouse("mouseDown", event: event, view: view, button: "right")

        case .rightMouseUp:
            sendMouse("mouseUp", event: event, view: view, button: "right")

        case .leftMouseDragged, .rightMouseDragged:
            sendMouse("mouseDrag", event: event, view: view)

        case .scrollWheel:
            let dy = Float(event.scrollingDeltaY)
            // Normalize: positive scroll delta = scroll down = increase scroll bar value
            let normalizedDy = event.hasPreciseScrollingDeltas ? dy / 500.0 : dy * 0.03
            onInputEvent?(["type": "scroll", "deltaY": -normalizedDy])

        case .keyDown:
            sendKey("keyDown", event: event)

        case .keyUp:
            sendKey("keyUp", event: event)

        default:
            break
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        // Modifier-only changes: forward as synthetic keyDown/keyUp
        // Not strictly needed for most use cases, but useful for apps that react to bare modifiers
    }

    // MARK: - Serialization helpers

    private func sendMouse(_ type: String, event: NSEvent, view: NSView, button: String? = nil) {
        let loc = view.convert(event.locationInWindow, from: nil)
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        // Normalize to 0–1 (flip Y: NSView origin is bottom-left, screen coords are top-left)
        let nx = Double(loc.x / bounds.width)
        let ny = Double(1.0 - loc.y / bounds.height)

        // Clamp — cursor can be slightly outside the view during drags
        guard nx >= -0.1, nx <= 1.1, ny >= -0.1, ny <= 1.1 else { return }

        var msg: [String: Any] = ["type": type, "x": nx, "y": ny]
        if let button { msg["button"] = button }
        onInputEvent?(msg)
    }

    private func sendKey(_ type: String, event: NSEvent) {
        var msg: [String: Any] = ["type": type, "keyCode": Int(event.keyCode)]
        let mods = event.modifierFlags
        if mods.contains(.shift)     { msg["shift"] = true }
        if mods.contains(.control)   { msg["control"] = true }
        if mods.contains(.option)    { msg["option"] = true }
        if mods.contains(.command)   { msg["command"] = true }

        // Include characters for text injection on the sender side
        if type == "keyDown", let chars = event.characters, !chars.isEmpty {
            msg["text"] = chars
        }
        onInputEvent?(msg)
    }
}
