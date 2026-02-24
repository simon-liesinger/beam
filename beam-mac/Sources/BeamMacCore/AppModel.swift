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
                    self?.receiverWindow?.close()
                    self?.receiverWindow = nil
                }
            }
        }
        activeSession = session
        session.acceptBeam(channel: channel, offer: offer)

        // Open ReceivingView in a new window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Beam - \(session.windowTitle)"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.acceptsMouseMovedEvents = true
        window.center()
        window.contentView = NSHostingView(rootView: ReceivingView(session: session))
        window.makeKeyAndOrderFront(nil)
        receiverWindow = window
    }
}
