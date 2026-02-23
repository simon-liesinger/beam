import Foundation
import Network

/// Advertises this Beam instance on the LAN and browses for other Beam instances.
/// Service type: _beam._tcp.
/// TXT record keys: version, platform, deviceID, name
class BonjourBrowser {
    private let deviceID: String
    private let deviceName: String
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "beam.bonjour")

    var onPeersChanged: (([PeerInfo]) -> Void)?

    init() {
        // Stable identity: persist to UserDefaults so it survives restarts
        if let saved = UserDefaults.standard.string(forKey: "beam.deviceID") {
            deviceID = saved
        } else {
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: "beam.deviceID")
            deviceID = id
        }
        deviceName = Host.current().localizedName ?? "Mac"
    }

    func start() {
        startAdvertising()
        startBrowsing()
    }

    func stop() {
        listener?.cancel()
        browser?.cancel()
    }

    // MARK: - Advertise

    private func startAdvertising() {
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            print("Bonjour: failed to create listener: \(error)")
            return
        }

        var txt = NWTXTRecord()
        txt["version"] = "1"
        txt["platform"] = "mac"
        txt["deviceID"] = deviceID
        txt["name"] = deviceName

        listener?.service = NWListener.Service(
            name: deviceName,
            type: "_beam._tcp.",
            txtRecord: txt
        )

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Bonjour: advertising as \"\(self.deviceName)\"")
            case .failed(let error):
                print("Bonjour: listener failed: \(error)")
            default:
                break
            }
        }

        // We don't accept connections yet — that's Week 4's TCPControlChannel
        listener?.newConnectionHandler = { connection in
            connection.cancel()
        }

        listener?.start(queue: queue)
    }

    // MARK: - Browse

    private func startBrowsing() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_beam._tcp.", domain: nil)
        browser = NWBrowser(for: descriptor, using: .tcp)

        browser?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Bonjour: browsing for peers")
            case .failed(let error):
                print("Bonjour: browser failed: \(error)")
            default:
                break
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let peers = results.compactMap { result -> PeerInfo? in
                guard case .bonjour(let txt) = result.metadata else { return nil }
                guard let peerID = txt["deviceID"], peerID != self.deviceID else { return nil }
                let name = txt["name"] ?? "Unknown"
                let platform = txt["platform"] ?? "mac"
                return PeerInfo(id: peerID, name: name, platform: platform, endpoint: result.endpoint)
            }
            DispatchQueue.main.async {
                self.onPeersChanged?(peers.sorted { $0.name < $1.name })
            }
        }

        browser?.start(queue: queue)
    }
}
