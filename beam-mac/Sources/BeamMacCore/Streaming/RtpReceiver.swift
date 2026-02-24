import Foundation

/// Receives RTP-like UDP packets and reassembles them into NAL units.
/// Uses BSD sockets — more reliable than NWListener for UDP across runs
/// (NWListener can enter a bad state after unclean shutdown).
class RtpReceiver {
    private var socket: Int32 = -1
    private let receiveQueue = DispatchQueue(label: "beam.rtp.receiver")

    /// Called on `receiveQueue` for each fully reassembled NAL unit.
    var onNAL: ((Data, Bool, UInt32) -> Void)?

    // MARK: - Fragment reassembly state

    // keyed by 90kHz RTP timestamp
    private var fragments:  [UInt32: [UInt16: Data]] = [:]   // timestamp -> [fragIndex: payload]
    private var fragCounts: [UInt32: UInt16] = [:]           // timestamp -> expected count
    private var fragFlags:  [UInt32: UInt8]  = [:]           // timestamp -> flags from first frag

    // MARK: - Start / Stop

    init(port: UInt16) {
        socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard socket >= 0 else { fatalError("RtpReceiver: failed to create socket") }

        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socket, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { fatalError("RtpReceiver: bind failed: \(errno)") }

        receiveQueue.async { [weak self] in self?.receiveLoop() }
        print("RtpReceiver: listening on port \(port)")
    }

    func stop() {
        let s = socket
        socket = -1
        if s >= 0 { Darwin.close(s) }
    }

    // MARK: - Receive loop

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while socket >= 0 {
            let n = recv(socket, &buffer, buffer.count, 0)
            guard n > 0 else {
                if n < 0 && errno != EAGAIN { break }
                continue
            }
            processPacket(Data(buffer[..<n]))
        }
    }

    // MARK: - Fragment reassembly

    private func processPacket(_ data: Data) {
        guard let hdr = rtpParseHeader(data) else { return }

        let payload = Data(data[rtpHeaderSize...])
        let ts = hdr.timestamp

        // Store fragment
        if fragments[ts] == nil { fragments[ts] = [:] }
        fragments[ts]![hdr.fragIndex] = payload
        fragCounts[ts] = hdr.fragCount
        if hdr.flags & RtpFlags.startOfNAL != 0 { fragFlags[ts] = hdr.flags }

        // Check if all fragments have arrived
        guard let frags = fragments[ts],
              let count = fragCounts[ts],
              frags.count == Int(count) else { return }

        // Reassemble in order
        var nalData = Data()
        for i in 0..<count {
            if let frag = frags[i] { nalData.append(frag) }
        }

        let isKeyframe = (fragFlags[ts] ?? hdr.flags) & RtpFlags.keyframe != 0

        fragments.removeValue(forKey: ts)
        fragCounts.removeValue(forKey: ts)
        fragFlags.removeValue(forKey: ts)

        onNAL?(nalData, isKeyframe, ts)

        // GC: drop fragments older than ~1 second of 90kHz clock
        let cutoff = hdr.timestamp &- 90_000
        for old in fragments.keys where old < cutoff && old < hdr.timestamp {
            fragments.removeValue(forKey: old)
            fragCounts.removeValue(forKey: old)
            fragFlags.removeValue(forKey: old)
        }
    }
}
