import ScreenCaptureKit

enum WindowPicker {
    /// Returns capturable windows, filtered to those with titles and reasonable sizes.
    static func listWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows.filter { window in
            guard let title = window.title, !title.isEmpty else { return false }
            guard window.frame.width > 100 && window.frame.height > 100 else { return false }
            return true
        }
    }
}
