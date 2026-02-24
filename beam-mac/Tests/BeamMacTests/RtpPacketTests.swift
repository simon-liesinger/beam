import Foundation
import Testing
@testable import BeamMacCore

@Suite("RTP Packet")
struct RtpPacketTests {

    // MARK: - Round-trip

    @Test func roundTrip() {
        let header = rtpMakeHeader(seq: 1234, timestamp: 9000,
                                   flags: RtpFlags.keyframe, fragIndex: 2, fragCount: 5)
        #expect(header.count == rtpHeaderSize)
        let parsed = rtpParseHeader(header)!
        #expect(parsed.seq       == 1234)
        #expect(parsed.timestamp == 9000)
        #expect(parsed.flags     == RtpFlags.keyframe)
        #expect(parsed.fragIndex == 2)
        #expect(parsed.fragCount == 5)
    }

    @Test func allFieldsAtMaxValues() {
        let header = rtpMakeHeader(seq: 0xFFFF, timestamp: 0xFFFFFFFF,
                                   flags: 0xFF, fragIndex: 0xFFFF, fragCount: 0xFFFF)
        let parsed = rtpParseHeader(header)!
        #expect(parsed.seq       == 0xFFFF)
        #expect(parsed.timestamp == 0xFFFFFFFF)
        #expect(parsed.flags     == 0xFF)
        #expect(parsed.fragIndex == 0xFFFF)
        #expect(parsed.fragCount == 0xFFFF)
    }

    @Test func zeroValues() {
        let header = rtpMakeHeader(seq: 0, timestamp: 0, flags: 0, fragIndex: 0, fragCount: 1)
        let parsed = rtpParseHeader(header)!
        #expect(parsed.seq == 0)
        #expect(parsed.timestamp == 0)
        #expect(parsed.flags == 0)
    }

    // MARK: - Byte layout (Android interop: must be exact big-endian)

    @Test func timestampBigEndian() {
        let header = rtpMakeHeader(seq: 0, timestamp: 0x12345678,
                                   flags: 0, fragIndex: 0, fragCount: 1)
        #expect(header[2] == 0x12)
        #expect(header[3] == 0x34)
        #expect(header[4] == 0x56)
        #expect(header[5] == 0x78)
    }

    @Test func seqBigEndian() {
        let header = rtpMakeHeader(seq: 0xABCD, timestamp: 0,
                                   flags: 0, fragIndex: 0, fragCount: 1)
        #expect(header[0] == 0xAB)
        #expect(header[1] == 0xCD)
    }

    @Test func fragmentFieldsBigEndian() {
        let header = rtpMakeHeader(seq: 0, timestamp: 0, flags: 0,
                                   fragIndex: 0x0102, fragCount: 0x0304)
        #expect(header[8]  == 0x01)
        #expect(header[9]  == 0x02)
        #expect(header[10] == 0x03)
        #expect(header[11] == 0x04)
    }

    @Test func flagsAtByte6ReservedZero() {
        let header = rtpMakeHeader(seq: 0, timestamp: 0, flags: 0x07,
                                   fragIndex: 0, fragCount: 1)
        #expect(header[6] == 0x07)
        #expect(header[7] == 0x00)
    }

    // MARK: - Flags

    @Test func flagValues() {
        #expect(RtpFlags.keyframe   == 0x01)
        #expect(RtpFlags.startOfNAL == 0x02)
        #expect(RtpFlags.endOfNAL   == 0x04)
    }

    @Test func flagsCombine() {
        let combined: UInt8 = RtpFlags.keyframe | RtpFlags.startOfNAL | RtpFlags.endOfNAL
        #expect(combined == 0x07)
    }

    // MARK: - Error handling

    @Test func tooShortReturnsNil() {
        #expect(rtpParseHeader(Data(repeating: 0, count: rtpHeaderSize - 1)) == nil)
    }

    @Test func emptyDataReturnsNil() {
        #expect(rtpParseHeader(Data()) == nil)
    }

    @Test func exactSizeParses() {
        #expect(rtpParseHeader(Data(repeating: 0, count: rtpHeaderSize)) != nil)
    }

    @Test func extraBytesIgnored() {
        var header = rtpMakeHeader(seq: 42, timestamp: 0, flags: 0,
                                   fragIndex: 0, fragCount: 1)
        header.append(contentsOf: [0xFF, 0xFF, 0xFF])
        #expect(rtpParseHeader(header)!.seq == 42)
    }

    // MARK: - Constants

    @Test func headerSizeIs12() {
        #expect(rtpHeaderSize == 12)
    }

    @Test func maxPayloadUnderMTU() {
        #expect(rtpMaxPayload <= 1500)
        #expect(rtpMaxPayload == 1400)
    }
}
