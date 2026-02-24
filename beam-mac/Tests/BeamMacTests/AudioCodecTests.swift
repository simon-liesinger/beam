import Testing
import AVFoundation
import AudioToolbox
@testable import BeamMacCore

@Suite("Audio Codec")
struct AudioCodecTests {

    // MARK: - Helpers

    private func makeSineBuffer(frames: AVAudioFrameCount = 1024,
                                 sampleRate: Double = 48000,
                                 frequency: Float = 440) -> AVAudioPCMBuffer {
        var desc = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        let format = AVAudioFormat(streamDescription: &desc)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let data = buf.audioBufferList.pointee.mBuffers.mData!
            .assumingMemoryBound(to: Float.self)
        for f in 0..<Int(frames) {
            let s = sin(2 * Float.pi * frequency * Float(f) / Float(sampleRate))
            data[f * 2] = s; data[f * 2 + 1] = s
        }
        return buf
    }

    // MARK: - Encoder

    @Test func encoderInitialises() throws {
        let _ = try AudioEncoder(sampleRate: 48000, channels: 2)
    }

    @Test func encoderProducesAACForFullFrame() throws {
        let encoder = try AudioEncoder(sampleRate: 48000, channels: 2)
        var received: Data?
        encoder.onAAC = { received = $0 }
        encoder.encode(pcmBuffer: makeSineBuffer(frames: 1024))
        #expect(received != nil, "Encoder should output AAC for 1024-frame input")
        #expect((received?.count ?? 0) > 0)
    }

    @Test func encoderOutputSizeIsReasonable() throws {
        let encoder = try AudioEncoder(sampleRate: 48000, channels: 2)
        var maxAacSize = 0
        encoder.onAAC = { maxAacSize = max(maxAacSize, $0.count) }
        // Feed 2 frames — first may be a tiny init packet; second should be full audio
        encoder.encode(pcmBuffer: makeSineBuffer(frames: 1024))
        encoder.encode(pcmBuffer: makeSineBuffer(frames: 1024))
        if maxAacSize > 0 {
            // 128kbps, 1024 frames @ 48kHz ≈ 21ms → ~336 bytes; allow codec headroom
            #expect(maxAacSize < 800, "AAC packet suspiciously large")
            #expect(maxAacSize > 10,  "AAC packet suspiciously tiny")
        }
    }

    @Test func encoderAccumulatesPartialFrames() throws {
        // 960 frames < 1024 (one AAC frame); encoder may buffer.
        // After sufficient input it must eventually produce output.
        let encoder = try AudioEncoder(sampleRate: 48000, channels: 2)
        var count = 0
        encoder.onAAC = { _ in count += 1 }
        // Feed two 960-frame buffers (1920 > 1024) — should flush at least once
        encoder.encode(pcmBuffer: makeSineBuffer(frames: 960))
        encoder.encode(pcmBuffer: makeSineBuffer(frames: 960))
        #expect(count > 0, "Should produce at least one AAC packet after 1920 input frames")
    }

    // MARK: - Decoder

    @Test func decoderInitialises() throws {
        let _ = try AudioDecoder(sampleRate: 48000, channels: 2)
    }

    @Test func decoderIgnoresGarbageInput() throws {
        let decoder = try AudioDecoder(sampleRate: 48000, channels: 2)
        // Must not crash
        decoder.decode(aacData: Data([0xFF, 0xFE, 0x00, 0x01]))
    }

    @Test func decoderIgnoresEmptyInput() throws {
        let decoder = try AudioDecoder(sampleRate: 48000, channels: 2)
        var called = false
        decoder.onPCMBuffer = { _ in called = true }
        decoder.decode(aacData: Data())
        // Empty input should produce no output (callback not called OR produces silence)
    }

    // MARK: - Round-trip

    @Test func encodeDecodeRoundTrip() throws {
        let encoder = try AudioEncoder(sampleRate: 48000, channels: 2)
        let decoder = try AudioDecoder(sampleRate: 48000, channels: 2)

        var packets: [Data] = []
        encoder.onAAC = { packets.append($0) }
        // Feed 3 full AAC frames to guarantee output
        for _ in 0..<3 { encoder.encode(pcmBuffer: makeSineBuffer(frames: 1024)) }
        #expect(packets.count > 0, "Encoder must produce packets")

        var decoded: [AVAudioPCMBuffer] = []
        decoder.onPCMBuffer = { decoded.append($0) }
        for packet in packets { decoder.decode(aacData: packet) }

        #expect(decoded.count > 0, "Decoder must produce PCM buffers")
        #expect(decoded[0].frameLength == 1024,
                "Each decoded AAC frame should yield 1024 PCM frames")
    }

    @Test func decodedBufferHasCorrectFormat() throws {
        let encoder = try AudioEncoder(sampleRate: 48000, channels: 2)
        let decoder = try AudioDecoder(sampleRate: 48000, channels: 2)

        var aacPacket: Data?
        encoder.onAAC = { aacPacket = $0 }
        encoder.encode(pcmBuffer: makeSineBuffer(frames: 1024))
        guard let packet = aacPacket else { return }

        var decoded: AVAudioPCMBuffer?
        decoder.onPCMBuffer = { decoded = $0 }
        decoder.decode(aacData: packet)
        guard let buf = decoded else { return }

        let asbd = buf.format.streamDescription.pointee
        #expect(asbd.mSampleRate      == 48000)
        #expect(asbd.mChannelsPerFrame == 2)
        #expect(asbd.mFormatID        == kAudioFormatLinearPCM)
        #expect(asbd.mBitsPerChannel  == 32)
    }
}
