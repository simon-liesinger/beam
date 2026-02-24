import Foundation
import Network

/// Fragments NAL units into RTP-like UDP packets and sends them to a peer.
class RtpSender {
    private let connection: NWConnection
    private var sequenceNumber: UInt16 = 0

    init(host: NWEndpoint.Host, port: NWEndpoint.Port) {
        connection = NWConnection(host: host, port: port, using: .udp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:            print("RtpSender: ready")
            case .failed(let err):  print("RtpSender: failed: \(err)")
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "beam.rtp.sender"))
    }

    func cancel() {
        connection.cancel()
    }

    /// Fragment a single NAL unit and send all chunks.
    func sendNAL(data: Data, isKeyframe: Bool, timestamp: UInt32) {
        let maxPayload = rtpMaxPayload - rtpHeaderSize
        let fragCount = UInt16((data.count + maxPayload - 1) / maxPayload)

        var offset = 0
        var fragIndex: UInt16 = 0

        while offset < data.count {
            let chunkSize = min(maxPayload, data.count - offset)
            let chunk = data[data.index(data.startIndex, offsetBy: offset)
                            ..<
                            data.index(data.startIndex, offsetBy: offset + chunkSize)]

            var flags: UInt8 = 0
            if isKeyframe          { flags |= RtpFlags.keyframe }
            if fragIndex == 0      { flags |= RtpFlags.startOfNAL }
            if fragIndex == fragCount - 1 { flags |= RtpFlags.endOfNAL }

            var packet = rtpMakeHeader(seq: sequenceNumber, timestamp: timestamp,
                                       flags: flags, fragIndex: fragIndex, fragCount: fragCount)
            packet.append(contentsOf: chunk)

            connection.send(content: packet, completion: .contentProcessed { _ in })

            sequenceNumber &+= 1
            offset += chunkSize
            fragIndex += 1
        }
    }
}
