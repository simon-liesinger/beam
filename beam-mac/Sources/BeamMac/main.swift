import AppKit
import SwiftUI
import BeamMacCore

// Explicit NSApplication setup — same pattern as the spikes, proven to work
// without a proper .app bundle. SwiftUI's @main WindowGroup has reliability
// issues when run as a terminal binary.

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// App icon: blue lightning bolt
do {
    let size = NSSize(width: 512, height: 512)
    let icon = NSImage(size: size)
    icon.lockFocus()

    // Background: rounded rect with gradient
    let bgPath = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                               xRadius: 112, yRadius: 112)
    let gradient = NSGradient(starting: NSColor(red: 0.15, green: 0.45, blue: 1.0, alpha: 1.0),
                               ending: NSColor(red: 0.35, green: 0.65, blue: 1.0, alpha: 1.0))!
    gradient.draw(in: bgPath, angle: -45)

    // Lightning bolt path (white)
    let bolt = NSBezierPath()
    bolt.move(to: NSPoint(x: 290, y: 460))   // top
    bolt.line(to: NSPoint(x: 180, y: 280))   // left mid
    bolt.line(to: NSPoint(x: 260, y: 280))   // center left
    bolt.line(to: NSPoint(x: 222, y: 52))    // bottom
    bolt.line(to: NSPoint(x: 332, y: 232))   // right mid
    bolt.line(to: NSPoint(x: 252, y: 232))   // center right
    bolt.close()
    NSColor.white.setFill()
    bolt.fill()

    icon.unlockFocus()
    app.applicationIconImage = icon
}

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
