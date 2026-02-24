import Foundation
import ScreenCaptureKit
import CoreMedia
import Network

/// Orchestrates a single beam: capture → encode → send (sender) or receive → decode → display (receiver).
/// Coordinates all components: WindowCapturer, H264Encoder/Decoder, RtpSender/Receiver,
/// AudioCapturer/Encoder/Decoder/Player, TCPControlChannel, WindowHider, InputInjector.
@Observable
class BeamSession {

    enum Role { case sender, receiver }
    enum State: String { case idle, connecting, active, stopping, stopped }

    private(set) var role: Role
    private(set) var state: State = .idle
    private(set) var peerName: String = ""
    private(set) var windowTitle: String = ""

    // Sender components
    private var windowCapturer: WindowCapturer?
    private var audioCapturer: AudioCapturer?
    private var h264Encoder: H264Encoder?
    private var audioEncoder: AudioEncoder?
    private var videoSender: RtpSender?
    private var audioSender: RtpSender?
    private var windowHider: WindowHider?
    private var inputInjector: InputInjector?
    private var hiddenAXWindow: AXUIElement?

    // Receiver components
    private var videoReceiver: RtpReceiver?
    private var audioReceiver: AudioReceiver?
    private var h264Decoder: H264Decoder?
    private var audioDecoder: AudioDecoder?
    private var audioPlayer: AudioPlayer?
    private var inputHandler: RemoteInputHandler?
    private(set) var streamView: StreamView?

    // Shared
    private var controlChannel: TCPControlChannel?

    // Ports (assigned dynamically, communicated via control channel)
    private var localVideoPort: UInt16 = 0
    private var localAudioPort: UInt16 = 0
    private var remoteVideoPort: UInt16 = 0
    private var remoteAudioPort: UInt16 = 0

    // Target window info (sender)
    private var targetWindow: SCWindow?
    private var targetPID: pid_t = 0

    var onStateChanged: ((State) -> Void)?

    init(role: Role) {
        self.role = role
    }

    // MARK: - Sender: Start Beam

    /// Sender: connect to peer's Bonjour endpoint and send beam_offer.
    func startBeam(peer: PeerInfo, window: SCWindow) {
        guard state == .idle else { return }
        role = .sender
        peerName = peer.name
        windowTitle = window.title ?? "Untitled"
        targetWindow = window
        targetPID = pid_t(window.owningApplication?.processID ?? 0)
        transition(to: .connecting)

        controlChannel = TCPControlChannel()
        controlChannel?.onMessage = { [weak self] msg in
            DispatchQueue.main.async { self?.handleControlMessage(msg) }
        }
        controlChannel?.onStateChanged = { [weak self] tcpState in
            DispatchQueue.main.async {
                guard let self else { return }
                if tcpState == .connected {
                    // Connected to peer — send beam_offer
                    let width = Int(window.frame.width)
                    let height = Int(window.frame.height)
                    self.controlChannel?.send(type: "beam_offer", payload: [
                        "senderName": Host.current().localizedName ?? "Mac",
                        "windowTitle": self.windowTitle,
                        "width": width,
                        "height": height,
                        "hasAudio": true,
                        "bundleID": window.owningApplication?.bundleIdentifier ?? "",
                    ])
                } else if tcpState == .disconnected {
                    self.stop()
                }
            }
        }

        // Connect directly to peer's Bonjour service endpoint
        controlChannel?.connect(to: peer.endpoint)
    }

    // MARK: - Receiver: Accept Beam

    /// Receiver: take ownership of the already-connected TCPControlChannel from AppModel.
    func acceptBeam(channel: TCPControlChannel, offer: [String: Any]) {
        guard state == .idle else { return }
        role = .receiver
        peerName = offer["senderName"] as? String ?? "Unknown"
        windowTitle = offer["windowTitle"] as? String ?? "Untitled"
        transition(to: .connecting)

        controlChannel = channel
        channel.onMessage = { [weak self] msg in
            DispatchQueue.main.async { self?.handleControlMessage(msg) }
        }
        channel.onStateChanged = { [weak self] tcpState in
            DispatchQueue.main.async {
                if tcpState == .disconnected { self?.stop() }
            }
        }

        let width = offer["width"] as? Int ?? 1920
        let height = offer["height"] as? Int ?? 1080
        setupReceiver(width: width, height: height, hasAudio: offer["hasAudio"] as? Bool ?? true)
    }

    // MARK: - Stop

    func stop() {
        guard state != .stopped && state != .stopping else { return }
        transition(to: .stopping)

        // Nil callbacks immediately so TCP disconnect events can't call stop() re-entrantly
        controlChannel?.onStateChanged = nil
        controlChannel?.onMessage = nil

        controlChannel?.send(type: "beam_end")

        if role == .sender {
            teardownSender()
        } else {
            teardownReceiver()
        }

        controlChannel?.stop()
        controlChannel = nil
        transition(to: .stopped)
    }

    // MARK: - Control Messages

    private func handleControlMessage(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }

        switch type {
        case "beam_accept":
            // Receiver accepted — they tell us their video/audio receive ports
            remoteVideoPort = UInt16(msg["videoPort"] as? Int ?? 0)
            remoteAudioPort = UInt16(msg["audioPort"] as? Int ?? 0)
            if role == .sender {
                // Get receiver's IP from the TCP connection's remote endpoint
                let host = controlChannel?.remoteHost ?? "127.0.0.1"
                setupSender(remoteHost: host)
            }

        case "beam_end":
            stop()

        case "input":
            // Input event from receiver → inject into sender's hidden window
            if role == .sender, let inputInjector, let hiddenAXWindow,
               let event = msg["event"] as? [String: Any],
               let frame = windowHider?.currentFrame(of: hiddenAXWindow) {
                inputInjector.apply(event: event, windowFrame: frame)
            }

        case "keyframe_request":
            h264Encoder?.forceKeyframe()

        default:
            break
        }
    }

    // MARK: - Sender Setup

    private func setupSender(remoteHost: String) {
        guard let window = targetWindow else { return }
        let width = Int(window.frame.width)
        let height = Int(window.frame.height)

        // Video pipeline: capture → encode → send
        windowCapturer = WindowCapturer()
        h264Encoder = H264Encoder(width: Int32(width), height: Int32(height))
        videoSender = RtpSender(host: .init(remoteHost), port: .init(rawValue: remoteVideoPort)!)

        h264Encoder?.onNAL = { [weak self] nalData, isKeyframe, timestamp in
            self?.videoSender?.sendNAL(data: nalData, isKeyframe: isKeyframe, timestamp: timestamp)
        }

        windowCapturer?.onFrame = { [weak self] pixelBuffer, pts in
            self?.h264Encoder?.encode(pixelBuffer: pixelBuffer, timestamp: pts)
        }

        // Audio pipeline: capture → encode → send
        do {
            audioEncoder = try AudioEncoder(sampleRate: 48000, channels: 2)
            audioSender = RtpSender(host: .init(remoteHost), port: .init(rawValue: remoteAudioPort)!)
            var audioSeq: UInt32 = 0
            audioEncoder?.onAAC = { [weak self] aacData in
                self?.audioSender?.sendNAL(data: aacData, isKeyframe: false, timestamp: audioSeq)
                audioSeq += 1
            }
        } catch {
            print("BeamSession: audio encoder init failed: \(error)")
        }

        // Input injection
        inputInjector = InputInjector(pid: targetPID)

        // Hide window on virtual display
        windowHider = WindowHider()
        if windowHider?.createDisplay() == true {
            hiddenAXWindow = windowHider?.hide(pid: targetPID, windowTitle: window.title)
            if let hiddenAXWindow {
                inputInjector?.setAXWindow(hiddenAXWindow)
            }
        }

        // Start capture
        Task {
            do {
                try await windowCapturer?.startCapture(window: window, width: width, height: height)

                // Start audio capture (needs display for SCK)
                if let display = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    .displays.first {
                    let app = window.owningApplication!
                    audioCapturer = AudioCapturer()
                    audioCapturer?.onPCMBuffer = { [weak self] buffer in
                        self?.audioEncoder?.encode(pcmBuffer: buffer)
                    }
                    try await audioCapturer?.start(app: app, display: display, mute: true)
                }

                transition(to: .active)
            } catch {
                print("BeamSession: capture start failed: \(error)")
                stop()
            }
        }
    }

    private func teardownSender() {
        let wc = windowCapturer
        let ac = audioCapturer
        Task {
            await wc?.stop()
            await ac?.stop()
        }
        windowCapturer = nil
        audioCapturer = nil
        h264Encoder = nil
        audioEncoder = nil
        videoSender = nil
        audioSender = nil
        inputInjector = nil
        windowHider?.destroyDisplay()
        windowHider = nil
        hiddenAXWindow = nil
    }

    // MARK: - Receiver Setup

    private func setupReceiver(width: Int, height: Int, hasAudio: Bool) {
        // Video pipeline: receive → decode → display
        h264Decoder = H264Decoder()
        streamView = StreamView()

        h264Decoder?.onFrame = { [weak self] pixelBuffer, pts in
            self?.streamView?.enqueue(pixelBuffer: pixelBuffer, timestamp: pts)
        }

        videoReceiver = RtpReceiver(port: 0)  // system-assigned port
        localVideoPort = videoReceiver?.localPort ?? 0

        videoReceiver?.onNAL = { [weak self] nalData, isKeyframe, timestamp in
            self?.h264Decoder?.decodeNAL(nalData, timestamp: timestamp)
        }

        // Audio pipeline: receive → decode → play
        if hasAudio {
            do {
                audioDecoder = try AudioDecoder(sampleRate: 48000, channels: 2)
                audioPlayer = try AudioPlayer()

                audioDecoder?.onPCMBuffer = { [weak self] buffer in
                    self?.audioPlayer?.play(interleavedBuffer: buffer)
                }

                audioReceiver = AudioReceiver(port: 0)
                localAudioPort = audioReceiver?.localPort ?? 0

                audioReceiver?.onAAC = { [weak self] aacData in
                    self?.audioDecoder?.decode(aacData: aacData)
                }
            } catch {
                print("BeamSession: audio decoder init failed: \(error)")
            }
        }

        // Input handler — attached when stream window is ready
        inputHandler = RemoteInputHandler()
        inputHandler?.onInputEvent = { [weak self] event in
            // Nest under "event" key so the "type" field (e.g. "mouseMove") is preserved;
            // the outer "type: input" is just the TCP message channel identifier.
            self?.controlChannel?.send(["type": "input", "event": event])
        }

        // Send beam_accept with our receive ports
        controlChannel?.send(type: "beam_accept", payload: [
            "videoPort": Int(localVideoPort),
            "audioPort": Int(localAudioPort),
        ])

        transition(to: .active)
    }

    private func teardownReceiver() {
        videoReceiver?.stop()
        videoReceiver = nil
        audioReceiver?.stop()
        audioReceiver = nil
        h264Decoder = nil
        audioDecoder = nil
        audioPlayer = nil
        inputHandler?.detach()
        inputHandler = nil
        streamView = nil
    }

    /// Attach the input handler to the stream view (called by ReceivingView after the window is ready).
    func attachInputHandler(to view: NSView) {
        inputHandler?.attach(to: view)
    }

    // MARK: - Private

    private func transition(to newState: State) {
        state = newState
        onStateChanged?(newState)
    }
}

// MARK: - AudioReceiver (thin RtpReceiver wrapper for audio)

/// Receives audio RTP packets on a UDP port. Thin wrapper around BSD sockets.
private class AudioReceiver {
    private var socket: Int32 = -1
    private var receiveQueue: DispatchQueue?
    private var running = false
    let localPort: UInt16

    var onAAC: ((Data) -> Void)?

    init?(port: UInt16) {
        // Dual-stack IPv6 socket for both IPv4 and IPv6
        let sock = Darwin.socket(AF_INET6, SOCK_DGRAM, 0)
        guard sock >= 0 else { localPort = 0; return nil }
        socket = sock

        var opt: Int32 = 1
        var off: Int32 = 0
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &opt, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindResult == 0 else {
            close(sock)
            localPort = 0
            return nil
        }

        // Read back assigned port
        var bound = sockaddr_in6()
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(sock, $0, &len)
            }
        }
        localPort = UInt16(bigEndian: bound.sin6_port)

        running = true
        receiveQueue = DispatchQueue(label: "beam.audio.recv")
        receiveQueue?.async { [weak self] in self?.receiveLoop() }
    }

    func stop() {
        running = false
        if socket >= 0 { close(socket); socket = -1 }
    }

    private func receiveLoop() {
        var buf = [UInt8](repeating: 0, count: 2000)
        while running {
            let n = recv(socket, &buf, buf.count, 0)
            guard n > rtpHeaderSize else { continue }

            // Strip RTP header, pass raw AAC payload
            let payload = Data(buf[rtpHeaderSize..<n])
            onAAC?(payload)
        }
    }
}
