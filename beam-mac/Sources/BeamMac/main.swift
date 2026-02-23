import AppKit
import SwiftUI

// Explicit NSApplication setup — same pattern as the spikes, proven to work
// without a proper .app bundle. SwiftUI's @main WindowGroup has reliability
// issues when run as a terminal binary.

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let model = AppModel()

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
window.title = "Beam"
window.center()
window.contentView = NSHostingView(rootView: MainView().environment(model))
window.makeKeyAndOrderFront(nil)

// Terminate when the main window is closed
NotificationCenter.default.addObserver(
    forName: NSWindow.willCloseNotification,
    object: window,
    queue: .main
) { _ in NSApp.terminate(nil) }

app.activate(ignoringOtherApps: true)

// NetService requires an active run loop for callbacks.
DispatchQueue.main.async { model.start() }

app.run()
