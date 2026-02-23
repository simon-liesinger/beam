import Foundation
import ScreenCaptureKit

@Observable
@MainActor
class AppModel {
    var peers: [PeerInfo] = []
    var windows: [SCWindow] = []
    var selectedPeer: PeerInfo?
    var selectedWindow: SCWindow?
    var isLoadingWindows = false

    private let browser: BonjourBrowser

    init() {
        browser = BonjourBrowser()
        browser.onPeersChanged = { [weak self] peers in
            self?.peers = peers
        }
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
