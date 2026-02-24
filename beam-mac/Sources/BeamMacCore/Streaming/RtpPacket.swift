import Foundation

// RTP-like packet header — 12 bytes
//
// Bytes 0-1:   sequence number  (UInt16, big-endian)
// Bytes 2-5:   timestamp        (UInt32, big-endian) — presentation time in 90kHz units
// Byte  6:     flags            (bit 0 = keyframe, bit 1 = start-of-NAL, bit 2 = end-of-NAL)
// Byte  7:     reserved
// Bytes 8-9:   fragment index   (UInt16, big-endian) — fragment number within NAL
// Bytes 10-11: fragment count   (UInt16, big-endian) — total fragments for this NAL

enum RtpFlags {
    static let keyframe:   UInt8 = 0x01
    static let startOfNAL: UInt8 = 0x02
    static let endOfNAL:   UInt8 = 0x04
}

let rtpHeaderSize = 12
let rtpMaxPayload = 1400  // stay under typical MTU

func rtpMakeHeader(seq: UInt16, timestamp: UInt32, flags: UInt8,
                   fragIndex: UInt16, fragCount: UInt16) -> Data {
    var h = Data(count: rtpHeaderSize)
    h[0]  = UInt8(seq >> 8);           h[1]  = UInt8(seq & 0xFF)
    h[2]  = UInt8(timestamp >> 24);    h[3]  = UInt8((timestamp >> 16) & 0xFF)
    h[4]  = UInt8((timestamp >> 8) & 0xFF); h[5] = UInt8(timestamp & 0xFF)
    h[6]  = flags;                     h[7]  = 0
    h[8]  = UInt8(fragIndex >> 8);     h[9]  = UInt8(fragIndex & 0xFF)
    h[10] = UInt8(fragCount >> 8);     h[11] = UInt8(fragCount & 0xFF)
    return h
}

struct RtpHeader {
    let seq: UInt16
    let timestamp: UInt32
    let flags: UInt8
    let fragIndex: UInt16
    let fragCount: UInt16
}

func rtpParseHeader(_ data: Data) -> RtpHeader? {
    guard data.count >= rtpHeaderSize else { return nil }
    let seq       = UInt16(data[0]) << 8 | UInt16(data[1])
    let timestamp = UInt32(data[2]) << 24 | UInt32(data[3]) << 16
                  | UInt32(data[4]) << 8  | UInt32(data[5])
    let flags     = data[6]
    let fragIndex = UInt16(data[8]) << 8 | UInt16(data[9])
    let fragCount = UInt16(data[10]) << 8 | UInt16(data[11])
    return RtpHeader(seq: seq, timestamp: timestamp, flags: flags,
                     fragIndex: fragIndex, fragCount: fragCount)
}
