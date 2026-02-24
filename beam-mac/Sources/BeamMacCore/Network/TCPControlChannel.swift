import Foundation
import Network

/// Bidirectional TCP channel for control messages (beam_offer, beam_accept, input, beam_end, ping/pong).
/// Framing: 4-byte big-endian length prefix + UTF-8 JSON payload.
/// Heartbeat: sends ping every 5s, expects pong within 10s or marks connection dead.
class TCPControlChannel {

    enum Role { case listener, connector }
    enum State { case idle, connecting, connected, disconnected }

    private(set) var state: State = .idle
    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "beam.tcp")

    private var heartbeatTimer: DispatchSourceTimer?
    private var lastPongTime: Date = Date()

    var onMessage: (([String: Any]) -> Void)?
    var onStateChanged: ((State) -> Void)?

    /// The remote peer's IP address (extracted from the NWConnection endpoint).
    var remoteHost: String? {
        guard let endpoint = connection?.currentPath?.remoteEndpoint,
              case .hostPort(let host, _) = endpoint else { return nil }
        return "\(host)"
    }

    // MARK: - Listen (sender side)

    /// Start listening on a system-assigned port. Returns the port via callback.
    func listen(onReady: @escaping (UInt16) -> Void) {
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            print("TCPControlChannel: listener init failed: \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                let port = self.listener?.port?.rawValue ?? 0
                print("TCPControlChannel: listening on port \(port)")
                onReady(port)
            case .failed(let err):
                print("TCPControlChannel: listener failed: \(err)")
                self.transition(to: .disconnected)
            default: break
            }
        }

        listener?.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            // Accept first connection, reject subsequent
            if self.connection != nil {
                conn.cancel()
                return
            }
            self.connection = conn
            self.startConnection(conn)
        }

        listener?.start(queue: queue)
        transition(to: .connecting)
    }

    // MARK: - Connect (sender side — to peer's Bonjour endpoint)

    func connect(to endpoint: NWEndpoint) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        startConnection(conn)
    }

    func connect(host: String, port: UInt16) {
        connect(to: .hostPort(host: .init(host), port: .init(rawValue: port)!))
    }

    // MARK: - Adopt (receiver side — wraps an already-accepted NWConnection)

    /// Wrap an NWConnection that was accepted by BonjourBrowser's NWListener.
    func adopt(connection conn: NWConnection) {
        connection = conn
        startConnection(conn)
    }

    // MARK: - Send

    func send(_ message: [String: Any]) {
        guard state == .connected, let conn = connection else { return }
        guard let json = try? JSONSerialization.data(withJSONObject: message) else { return }

        var header = UInt32(json.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(json)

        conn.send(content: frame, completion: .contentProcessed { error in
            if let error {
                print("TCPControlChannel: send error: \(error)")
            }
        })
    }

    /// Convenience: send a typed message.
    func send(type: String, payload: [String: Any] = [:]) {
        var msg = payload
        msg["type"] = type
        send(msg)
    }

    // MARK: - Stop

    func stop() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        transition(to: .disconnected)
    }

    // MARK: - Private

    private func startConnection(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                self.transition(to: .connected)
                self.startReceiveLoop()
                self.startHeartbeat()
            case .failed, .cancelled:
                self.transition(to: .disconnected)
            default: break
            }
        }
        conn.start(queue: queue)
        transition(to: .connecting)
    }

    private func startReceiveLoop() {
        receiveNextMessage()
    }

    private func receiveNextMessage() {
        guard let conn = connection, state == .connected else { return }

        // Read 4-byte length header
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self, let data, data.count == 4 else {
                if let error { print("TCPControlChannel: header read error: \(error)") }
                self?.transition(to: .disconnected)
                return
            }

            let length = Int(data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard length > 0, length < 1_000_000 else {
                print("TCPControlChannel: invalid frame length \(length)")
                self.transition(to: .disconnected)
                return
            }

            // Read payload
            conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] payload, _, _, error in
                guard let self, let payload, payload.count == length else {
                    if let error { print("TCPControlChannel: payload read error: \(error)") }
                    self?.transition(to: .disconnected)
                    return
                }

                if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                    self.handleMessage(json)
                }

                self.receiveNextMessage()
            }
        }
    }

    private func handleMessage(_ msg: [String: Any]) {
        let type = msg["type"] as? String ?? ""

        if type == "ping" {
            send(type: "pong")
            return
        }
        if type == "pong" {
            lastPongTime = Date()
            return
        }

        onMessage?(msg)
    }

    private func startHeartbeat() {
        lastPongTime = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.state == .connected else { return }
            // Check for stale connection
            if Date().timeIntervalSince(self.lastPongTime) > 10 {
                print("TCPControlChannel: heartbeat timeout")
                self.transition(to: .disconnected)
                self.connection?.cancel()
                return
            }
            self.send(type: "ping")
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func transition(to newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChanged?(newState)
    }
}
