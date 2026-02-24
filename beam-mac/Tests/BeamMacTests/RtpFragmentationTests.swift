import Foundation
import Testing
@testable import BeamMacCore

@Suite("RTP Fragmentation")
struct RtpFragmentationTests {

    // MARK: - Helpers

    private func fragment(nalData: Data, isKeyframe: Bool,
                          timestamp: UInt32) -> [Data] {
        let maxPayload = rtpMaxPayload - rtpHeaderSize
        let fragCount = UInt16((nalData.count + maxPayload - 1) / maxPayload)
        var packets: [Data] = []
        var seqNum: UInt16 = 0
        var fragIndex: UInt16 = 0
        var offset = 0

        while offset < nalData.count {
            let chunkSize = min(maxPayload, nalData.count - offset)
            let chunk = nalData[offset ..< offset + chunkSize]

            var flags: UInt8 = 0
            if isKeyframe                      { flags |= RtpFlags.keyframe }
            if fragIndex == 0                  { flags |= RtpFlags.startOfNAL }
            if fragIndex == fragCount - 1      { flags |= RtpFlags.endOfNAL }

            var packet = rtpMakeHeader(seq: seqNum, timestamp: timestamp,
                                       flags: flags, fragIndex: fragIndex,
                                       fragCount: fragCount)
            packet.append(contentsOf: chunk)
            packets.append(packet)

            seqNum &+= 1
            fragIndex += 1
            offset += chunkSize
        }
        return packets
    }

    private func reassemble(packets: [Data]) -> Data? {
        guard let first = packets.first,
              let firstHdr = rtpParseHeader(first),
              packets.count == Int(firstHdr.fragCount) else { return nil }
        var result = Data()
        for packet in packets { result.append(packet[rtpHeaderSize...]) }
        return result
    }

    // MARK: - Packet count

    @Test func smallNALFitsInOnePacket() {
        let packets = fragment(nalData: Data(repeating: 0x67, count: 100),
                               isKeyframe: true, timestamp: 0)
        #expect(packets.count == 1)
    }

    @Test func largeNALSplitsIntoMultiplePackets() {
        let packets = fragment(nalData: Data(repeating: 0x41, count: 3000),
                               isKeyframe: false, timestamp: 0)
        #expect(packets.count == 3)
    }

    @Test func exactlyOneMaxPayload() {
        let nal = Data(repeating: 0x01, count: rtpMaxPayload - rtpHeaderSize)
        #expect(fragment(nalData: nal, isKeyframe: false, timestamp: 0).count == 1)
    }

    @Test func oneByteOverMaxPayload() {
        let nal = Data(repeating: 0x01, count: rtpMaxPayload - rtpHeaderSize + 1)
        #expect(fragment(nalData: nal, isKeyframe: false, timestamp: 0).count == 2)
    }

    // MARK: - Flag correctness

    @Test func firstPacketHasStartFlag() {
        let packets = fragment(nalData: Data(repeating: 0, count: 3000),
                               isKeyframe: false, timestamp: 0)
        let hdr = rtpParseHeader(packets.first!)!
        #expect(hdr.flags & RtpFlags.startOfNAL != 0)
        #expect(hdr.flags & RtpFlags.endOfNAL   == 0)
    }

    @Test func lastPacketHasEndFlag() {
        let packets = fragment(nalData: Data(repeating: 0, count: 3000),
                               isKeyframe: false, timestamp: 0)
        let hdr = rtpParseHeader(packets.last!)!
        #expect(hdr.flags & RtpFlags.endOfNAL   != 0)
        #expect(hdr.flags & RtpFlags.startOfNAL == 0)
    }

    @Test func middlePacketHasNeitherBoundaryFlag() {
        let packets = fragment(nalData: Data(repeating: 0, count: 5000),
                               isKeyframe: false, timestamp: 0)
        #expect(packets.count > 2)
        let hdr = rtpParseHeader(packets[1])!
        #expect(hdr.flags & RtpFlags.startOfNAL == 0)
        #expect(hdr.flags & RtpFlags.endOfNAL   == 0)
    }

    @Test func singlePacketHasBothBoundaryFlags() {
        let packets = fragment(nalData: Data(repeating: 0, count: 100),
                               isKeyframe: false, timestamp: 0)
        #expect(packets.count == 1)
        let hdr = rtpParseHeader(packets[0])!
        #expect(hdr.flags & RtpFlags.startOfNAL != 0)
        #expect(hdr.flags & RtpFlags.endOfNAL   != 0)
    }

    @Test func keyframeFlagOnAllFragments() {
        let packets = fragment(nalData: Data(repeating: 0, count: 3000),
                               isKeyframe: true, timestamp: 0)
        for packet in packets {
            #expect(rtpParseHeader(packet)!.flags & RtpFlags.keyframe != 0)
        }
    }

    @Test func nonKeyframeHasNoKeyframeFlag() {
        let packets = fragment(nalData: Data(repeating: 0, count: 100),
                               isKeyframe: false, timestamp: 0)
        #expect(rtpParseHeader(packets[0])!.flags & RtpFlags.keyframe == 0)
    }

    // MARK: - Sequence and fragment indexes

    @Test func sequenceNumbersIncrement() {
        let packets = fragment(nalData: Data(repeating: 0, count: 5000),
                               isKeyframe: false, timestamp: 0)
        for (i, packet) in packets.enumerated() {
            #expect(rtpParseHeader(packet)!.seq == UInt16(i))
        }
    }

    @Test func fragmentIndexesAreCorrect() {
        let packets = fragment(nalData: Data(repeating: 0, count: 3000),
                               isKeyframe: false, timestamp: 0)
        for (i, packet) in packets.enumerated() {
            let hdr = rtpParseHeader(packet)!
            #expect(hdr.fragIndex == UInt16(i))
            #expect(hdr.fragCount == UInt16(packets.count))
        }
    }

    // MARK: - Reassembly

    @Test func reassemblyRecovarsOriginalData() {
        let original = Data((0..<3000).map { UInt8($0 & 0xFF) })
        let packets  = fragment(nalData: original, isKeyframe: false, timestamp: 0)
        #expect(reassemble(packets: packets) == original)
    }

    @Test func singlePacketReassembly() {
        let original = Data([0x65, 0x88, 0x84, 0x00, 0x33, 0x00])
        let packets  = fragment(nalData: original, isKeyframe: true, timestamp: 90000)
        #expect(reassemble(packets: packets) == original)
    }

    @Test func timestampPreservedAcrossFragments() {
        let ts: UInt32 = 0xDEADBEEF
        let packets = fragment(nalData: Data(repeating: 0, count: 3000),
                               isKeyframe: false, timestamp: ts)
        for packet in packets {
            #expect(rtpParseHeader(packet)!.timestamp == ts)
        }
    }
}
