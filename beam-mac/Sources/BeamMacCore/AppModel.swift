import Foundation
import ScreenCaptureKit
import SwiftUI
import Network

@Observable
public class AppModel {
    var peers: [PeerInfo] = []
    var windows: [SCWindow] = []
    var selectedPeer: PeerInfo?
    var selectedWindow: SCWindow?
    var isLoadingWindows = false
    var searchText: String = ""
    var windowError: String?
    var updateLabel: String = AppModel.idleUpdateLabel
    var isCheckingUpdate = false

    /// Active beam session (sender or receiver). Nil when idle.
    var activeSession: BeamSession?

    /// Filtered windows based on search text (matches window title or app name).
    var filteredWindows: [SCWindow] {
        guard !searchText.isEmpty else { return windows }
        let query = searchText.lowercased()
        return windows.filter { w in
            let title = (w.title ?? "").lowercased()
            let app = (w.owningApplication?.applicationName ?? "").lowercased()
            return title.contains(query) || app.contains(query)
        }
    }

    private let browser: BonjourBrowser

    /// Pending incoming connection waiting for beam_offer.
    private var pendingChannel: TCPControlChannel?

    /// The receiver window (kept alive while receiving).
    private var receiverWindow: NSWindow?

    public init() {
        browser = BonjourBrowser()
        browser.onPeersChanged = { [weak self] peers in
            self?.peers = peers
        }
        browser.onIncomingConnection = { [weak self] conn in
            DispatchQueue.main.async { self?.handleIncomingConnection(conn) }
        }
    }

    /// Call once the main run loop is running (from DispatchQueue.main.async in main.swift).
    public func start() {
        browser.start()
        Task { await refreshWindows() }
    }

    func refreshWindows() async {
        isLoadingWindows = true
        defer { isLoadingWindows = false }

        do {
            let result = try await WindowPicker.listWindows()
            windows = result.windows
            windowError = result.permissionDenied
                ? "Screen recording permission not granted. Grant in System Settings → Privacy & Security → Screen Recording, then restart Beam."
                : nil
            if let sel = selectedWindow, !windows.contains(where: { $0.windowID == sel.windowID }) {
                selectedWindow = nil
            }
        } catch {
            windows = []
            windowError = "\(error)"
        }
    }

    /// Start beaming the selected window to the selected peer.
    func startBeam() {
        guard let peer = selectedPeer, let window = selectedWindow else { return }
        let session = BeamSession(role: .sender)
        session.onStateChanged = { [weak self] state in
            if state == .stopped {
                DispatchQueue.main.async { self?.activeSession = nil }
            }
        }
        activeSession = session
        session.startBeam(peer: peer, window: window)
    }

    /// Stop the current beam session.
    func stopBeam() {
        activeSession?.stop()
        receiverWindow?.close()
        receiverWindow = nil
    }

    // MARK: - Updates

    private static var idleUpdateLabel: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(v) — Check for Updates…"
    }

    func checkForUpdates() {
        isCheckingUpdate = true
        updateLabel = "Checking…"
        Updater.check { [weak self] state in
            guard let self else { return }
            self.isCheckingUpdate = false
            switch state {
            case .checking:
                self.updateLabel = "Checking…"
                self.isCheckingUpdate = true
            case .downloading:
                self.updateLabel = "Downloading…"
                self.isCheckingUpdate = true
            case .installing:
                self.updateLabel = "Installing…"
                self.isCheckingUpdate = true
            case .upToDate:
                self.updateLabel = "Up to date"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.updateLabel = AppModel.idleUpdateLabel
                }
            case .error(let msg):
                self.updateLabel = "Failed: \(msg)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    self.updateLabel = AppModel.idleUpdateLabel
                }
            case .idle:
                self.updateLabel = AppModel.idleUpdateLabel
            }
        }
    }

    // MARK: - Incoming Beam

    private func handleIncomingConnection(_ conn: NWConnection) {
        if activeSession != nil { conn.cancel(); return }

        let channel = TCPControlChannel()
        pendingChannel = channel

        channel.onMessage = { [weak self] msg in
            guard let self else { return }
            if (msg["type"] as? String) == "beam_offer" {
                DispatchQueue.main.async { self.acceptIncomingBeam(channel: channel, offer: msg) }
            }
        }
        channel.onStateChanged = { [weak self] state in
            if state == .disconnected {
                self?.pendingChannel = nil
            }
        }
        channel.adopt(connection: conn)
    }

    private func acceptIncomingBeam(channel: TCPControlChannel, offer: [String: Any]) {
        pendingChannel = nil

        let session = BeamSession(role: .receiver)
        session.onStateChanged = { [weak self] state in
            if state == .stopped {
                DispatchQueue.main.async {
                    self?.activeSession = nil
                    // Detach SwiftUI and hide window without animation to prevent
                    // use-after-free in _NSWindowTransformAnimation during CA commit.
                    self?.receiverWindow?.contentView = NSView()
                    self?.receiverWindow?.orderOut(nil)
                    self?.receiverWindow = nil
                    // Bring main window to front so the app doesn't appear to have quit
                    if let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible }) {
                        mainWindow.makeKeyAndOrderFront(nil)
                    }
                    NSApp.activate()
                }
            }
        }
        activeSession = session
        session.acceptBeam(channel: channel, offer: offer)

        // Open ReceivingView in a new window — use offer dimensions so aspect ratio matches.
        // With fullSizeContentView the content view fills the entire window frame,
        // so compute contentRect such that the frame equals offerW x offerH exactly.
        let offerW = offer["width"] as? Int ?? 1280
        let offerH = offer["height"] as? Int ?? 720
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        let frameRect = NSRect(x: 0, y: 0, width: offerW, height: offerH)
        let contentRect = NSWindow.contentRect(forFrameRect: frameRect, styleMask: style)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = "Beam - \(session.windowTitle)"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // NOTE: do NOT set isMovableByWindowBackground — it consumes all clicks,
        // preventing them from reaching the content view / RemoteInputHandler.
        // The transparent title bar still allows dragging from the top edge.
        window.backgroundColor = .black
        window.acceptsMouseMovedEvents = true
        // Disable window animations to prevent _NSWindowTransformAnimation
        // use-after-free crash during CA transaction commit on window close.
        window.animationBehavior = .none
        window.center()
        window.contentView = NSHostingView(rootView: ReceivingView(session: session))
        window.makeKeyAndOrderFront(nil)
        receiverWindow = window

        // Stop the session if the user closes the window with the X button
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { [weak self, weak session] _ in
            self?.receiverWindow = nil  // nil first so session.stop()'s close() call is a no-op
            session?.stop()
            self?.activeSession = nil
        }
    }
}
