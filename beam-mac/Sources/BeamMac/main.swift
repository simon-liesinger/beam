import AppKit
import SwiftUI
import BeamMacCore

// Explicit NSApplication setup — same pattern as the spikes, proven to work
// without a proper .app bundle. SwiftUI's @main WindowGroup has reliability
// issues when run as a terminal binary.

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Main menu (gives us Cmd-Q, Cmd-W, etc.)
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(NSMenuItem(title: "About Beam", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
appMenu.addItem(.separator())
appMenu.addItem(NSMenuItem(title: "Quit Beam", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
appMenuItem.submenu = appMenu
mainMenu.addItem(appMenuItem)
app.mainMenu = mainMenu

let model = AppModel()

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
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
