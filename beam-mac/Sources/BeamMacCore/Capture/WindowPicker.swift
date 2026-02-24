import ScreenCaptureKit
import CoreGraphics

enum WindowPicker {

    struct Result {
        let windows: [SCWindow]
        /// True if SCShareableContent returned windows but none had titles — means permission not granted.
        let permissionDenied: Bool
    }

    /// Returns capturable windows, filtered to real user-visible windows.
    /// Also reports whether the results indicate a permission problem.
    static func listWindows() async throws -> Result {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)

        let candidates = content.windows.filter { w in
            // Normal window layer only (excludes menu bar, dock, overlays, tooltips, etc.)
            guard w.windowLayer == 0 else { return false }
            // Non-zero size (excludes hidden helper/IPC windows)
            guard w.frame.width > 0 && w.frame.height > 0 else { return false }
            return true
        }

        let withTitles = candidates.filter { window in
            guard let title = window.title, !title.isEmpty else { return false }
            if window.owningApplication?.bundleIdentifier == "com.beam.mac" { return false }
            return true
        }

        // If there are many on-screen windows but none have titles,
        // screen recording permission hasn't been granted (titles are redacted).
        let permissionDenied = withTitles.isEmpty && candidates.count > 3

        return Result(windows: withTitles, permissionDenied: permissionDenied)
    }
}
