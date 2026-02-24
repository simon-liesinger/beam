import Foundation
import AppKit

/// Downloads and installs updates from GitHub Releases.
/// Checks simon-liesinger/beam for a release tagged newer than the current version.
class Updater {
    static let repo = "simon-liesinger/beam"

    enum State {
        case idle, checking, downloading(Double), installing, upToDate, error(String)
    }

    static func check(completion: @escaping (State) -> Void) {
        completion(.checking)

        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                DispatchQueue.main.async {
                    completion(.error(error?.localizedDescription ?? "Failed to reach GitHub"))
                }
                return
            }

            let remoteVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

            guard compareVersions(remoteVersion, isNewerThan: currentVersion) else {
                DispatchQueue.main.async { completion(.upToDate) }
                return
            }

            // Find DMG asset
            guard let assets = json["assets"] as? [[String: Any]],
                  let dmgAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
                  let downloadURL = dmgAsset["browser_download_url"] as? String,
                  let url = URL(string: downloadURL) else {
                DispatchQueue.main.async { completion(.error("No DMG asset in release \(tagName)")) }
                return
            }

            DispatchQueue.main.async { completion(.downloading(0)) }
            downloadAndInstall(url: url, version: remoteVersion, completion: completion)
        }.resume()
    }

    private static func downloadAndInstall(url: URL, version: String, completion: @escaping (State) -> Void) {
        let task = URLSession.shared.downloadTask(with: url) { tempURL, _, error in
            guard let tempURL, error == nil else {
                DispatchQueue.main.async {
                    completion(.error("Download failed: \(error?.localizedDescription ?? "unknown")"))
                }
                return
            }

            // Copy temp file before the handler returns (URLSession deletes it afterward)
            let localDMG = FileManager.default.temporaryDirectory
                .appendingPathComponent("Beam-update-\(UUID().uuidString).dmg")
            do {
                try FileManager.default.copyItem(at: tempURL, to: localDMG)
            } catch {
                DispatchQueue.main.async { completion(.error("Could not stage DMG: \(error.localizedDescription)")) }
                return
            }

            DispatchQueue.main.async { completion(.installing) }

            do {
                try install(dmgURL: localDMG)
                // If we get here without relaunching, something went wrong
            } catch {
                try? FileManager.default.removeItem(at: localDMG)
                let msg = error.localizedDescription
                DispatchQueue.main.async {
                    // Last resort: open the DMG in Finder so the user can drag manually
                    NSWorkspace.shared.open(localDMG)
                    completion(.error("Auto-install failed (\(msg)) — DMG opened for manual install"))
                }
            }
        }
        task.resume()
    }

    private static func install(dmgURL: URL) throws {
        let fm = FileManager.default

        // Create mount point directory (hdiutil -mountpoint requires it to exist)
        let mountPoint = fm.temporaryDirectory
            .appendingPathComponent("beam-mount-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)

        let mountProcess = Process()
        mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        mountProcess.arguments = ["attach", dmgURL.path, "-mountpoint", mountPoint, "-nobrowse", "-quiet"]
        try mountProcess.run()
        mountProcess.waitUntilExit()
        guard mountProcess.terminationStatus == 0 else {
            throw UpdateError("Failed to mount DMG (hdiutil exit \(mountProcess.terminationStatus))")
        }

        defer {
            // Always detach
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint, "-quiet", "-force"]
            try? detach.run()
            detach.waitUntilExit()
            try? fm.removeItem(atPath: mountPoint)
        }

        let sourceApp = "\(mountPoint)/Beam.app"
        guard fm.fileExists(atPath: sourceApp) else {
            throw UpdateError("Beam.app not found in DMG")
        }

        // Replace the running bundle
        let currentApp = Bundle.main.bundlePath

        // Try direct copy first (works if app is in a user-writable location)
        var installedDirectly = false
        if fm.isWritableFile(atPath: (currentApp as NSString).deletingLastPathComponent) {
            let backupPath = currentApp + ".bak"
            try? fm.removeItem(atPath: backupPath)
            if (try? fm.moveItem(atPath: currentApp, toPath: backupPath)) != nil {
                if (try? fm.copyItem(atPath: sourceApp, toPath: currentApp)) != nil {
                    try? fm.removeItem(atPath: backupPath)
                    installedDirectly = true
                } else {
                    // Restore backup on copy failure
                    try? fm.moveItem(atPath: backupPath, toPath: currentApp)
                }
            }
        }

        // Fall back to AppleScript with admin privileges (needed for /Applications)
        if !installedDirectly {
            let escaped = sourceApp.replacingOccurrences(of: "'", with: "'\\''")
            let dest = currentApp.replacingOccurrences(of: "'", with: "'\\''")
            let shell = "rm -rf '\(dest)' && cp -R '\(escaped)' '\(dest)'"
            let script = "do shell script \"\(shell.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"

            let osascript = Process()
            osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osascript.arguments = ["-e", script]
            let pipe = Pipe()
            osascript.standardError = pipe
            try osascript.run()
            osascript.waitUntilExit()
            guard osascript.terminationStatus == 0 else {
                let errData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                throw UpdateError("Admin install failed: \(errMsg)")
            }
        }

        // Relaunch
        let relaunchPath = currentApp + "/Contents/MacOS/BeamMac"
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: relaunchPath)
        try? relaunch.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private static func compareVersions(_ remote: String, isNewerThan local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}

private struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
