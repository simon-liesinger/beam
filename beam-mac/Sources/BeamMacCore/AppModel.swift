import Foundation
import ScreenCaptureKit

@Observable
public class AppModel {
    var peers: [PeerInfo] = []
    var windows: [SCWindow] = []
    var selectedPeer: PeerInfo?
    var selectedWindow: SCWindow?
    var isLoadingWindows = false

    private let browser: BonjourBrowser

    public init() {
        browser = BonjourBrowser()
        browser.onPeersChanged = { [weak self] peers in
            self?.peers = peers
        }
    }

    /// Call once the main run loop is running (from DispatchQueue.main.async in main.swift).
    /// NetServiceBrowser and NetService require an active run loop for callbacks.
    public func start() {
        browser.start()
        Task { await refreshWindows() }
    }

    func refreshWindows() async {
        isLoadingWindows = true
        defer { isLoadingWindows = false }
        do {
            windows = try await WindowPicker.listWindows()
            // Clear selection if the selected window is no longer available
            if let sel = selectedWindow, !windows.contains(where: { $0.windowID == sel.windowID }) {
                selectedWindow = nil
            }
        } catch {
            print("Failed to list windows: \(error)")
        }
    }
}
