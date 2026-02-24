import Foundation
import Network

// NWListener to advertise, NWBrowser(.tcp) to discover service names,
// NetService.resolve() (on main run loop) to fetch TXT records.
// NWBrowser metadata is always <none> so we must resolve separately.

class BonjourBrowser: NSObject, NetServiceDelegate {
    private let deviceID: String
    private let deviceName: String

    private var listener: NWListener?
    private var browser: NWBrowser?
    private let bgQueue = DispatchQueue(label: "beam.bonjour")

    private var resolvingServices: [NetService] = []  // must stay alive during resolve

    var onPeersChanged: (([PeerInfo]) -> Void)?
    /// Called when a remote peer connects to our listener (incoming beam request).
    var onIncomingConnection: ((NWConnection) -> Void)?

    override init() {
        deviceID = UUID().uuidString
        deviceName = Host.current().localizedName ?? "Mac"
        super.init()
    }

    func start() {
        startAdvertising()
        startBrowsing()
    }

    func stop() {
        listener?.cancel()
        browser?.cancel()
    }

    // MARK: - Advertise via NWListener (proven: NWBrowser finds it)

    private func startAdvertising() {
        do { listener = try NWListener(using: .tcp) }
        catch { print("Bonjour: listener init failed: \(error)"); return }

        var txt = NWTXTRecord()
        txt["version"]  = "1"
        txt["platform"] = "mac"
        txt["deviceID"] = deviceID
        txt["name"]     = deviceName

        listener?.service = NWListener.Service(name: deviceName, type: "_beam._tcp.",
                                               txtRecord: txt)
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:            print("Bonjour: advertising as \"\(self?.deviceName ?? "")\"")
            case .failed(let err):  print("Bonjour: listener failed: \(err)")
            default: break
            }
        }
        listener?.newConnectionHandler = { [weak self] conn in
            self?.onIncomingConnection?(conn)
        }
        listener?.start(queue: bgQueue)
    }

    // MARK: - Discover via NWBrowser(.tcp) (proven: browseResultsChangedHandler fires)

    private func startBrowsing() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_beam._tcp.", domain: nil)
        browser = NWBrowser(for: descriptor, using: .tcp)

        browser?.stateUpdateHandler = { state in
            switch state {
            case .ready:           print("Bonjour: browser ready")
            case .failed(let err): print("Bonjour: browser failed: \(err)")
            default: break
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async { self?.resolveAll(results) }
        }

        browser?.start(queue: bgQueue)
    }

    // MARK: - Resolve TXT records (NetService.resolve, called on main run loop)

    private func resolveAll(_ results: Set<NWBrowser.Result>) {
        resolvingServices.removeAll()

        for result in results {
            guard case let NWEndpoint.service(name: name, type: type, domain: domain,
                                              interface: _) = result.endpoint else { continue }
            let svc = NetService(domain: domain, type: type, name: name)
            svc.delegate = self
            svc.schedule(in: .main, forMode: .common)
            svc.resolve(withTimeout: 5.0)
            resolvingServices.append(svc)
        }
    }

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        publishPeers()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        print("Bonjour: resolve failed for \(sender.name): \(errorDict)")
        publishPeers()
    }

    // MARK: - Build peer list

    private func publishPeers() {
        let peers: [PeerInfo] = resolvingServices.compactMap { svc -> PeerInfo? in
            guard let txtData = svc.txtRecordData() else { return nil }
            let dict = NetService.dictionary(fromTXTRecord: txtData)

            guard let idData  = dict["deviceID"],
                  let peerID  = String(data: idData, encoding: .utf8),
                  peerID != deviceID
            else { return nil }

            let name     = dict["name"].flatMap     { String(data: $0, encoding: .utf8) } ?? svc.name
            let platform = dict["platform"].flatMap { String(data: $0, encoding: .utf8) } ?? "mac"
            let endpoint = NWEndpoint.service(name: svc.name, type: svc.type,
                                              domain: svc.domain, interface: nil)
            return PeerInfo(id: peerID, name: name, platform: platform, endpoint: endpoint)
        }

        onPeersChanged?(peers.sorted { $0.name < $1.name })
    }
}
