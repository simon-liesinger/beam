import Foundation
import AudioToolbox
import AVFoundation

/// Encodes interleaved Float32 PCM to AAC-LC using AudioToolbox.
/// Feed 960-frame buffers from AudioCapturer, get AAC Data packets out.
class AudioEncoder {
    private var converter: AudioConverterRef?
    private var inputBuffer: AVAudioPCMBuffer?
    private let channels: UInt32

    /// Called for each encoded AAC packet (~47/sec at 48kHz with 1024-frame AAC packets).
    var onAAC: ((Data) -> Void)?

    init(sampleRate: Float64 = 48000, channels: UInt32 = 2) throws {
        self.channels = channels

        var inFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var outFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var conv: AudioConverterRef?
        let err = AudioConverterNew(&inFormat, &outFormat, &conv)
        guard err == noErr, let c = conv else {
            throw AudioError.osstatus("AudioEncoder: AudioConverterNew", err)
        }
        converter = c

        var bitrate: UInt32 = channels > 1 ? 128_000 : 64_000
        AudioConverterSetProperty(c, kAudioConverterEncodeBitRate,
                                  UInt32(MemoryLayout<UInt32>.size), &bitrate)
    }

    func encode(pcmBuffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }
        inputBuffer = pcmBuffer

        let maxOutputSize: UInt32 = 4096
        let outputData = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(maxOutputSize))
        defer { outputData.deallocate() }

        var outputBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channels,
                mDataByteSize: maxOutputSize,
                mData: outputData
            )
        )

        var outputPacketCount: UInt32 = 1
        var outputPacketDescription = AudioStreamPacketDescription()

        let err = AudioConverterFillComplexBuffer(
            converter,
            { (_, ioNumberDataPackets, ioData, _, inUserData) -> OSStatus in
                let encoder = Unmanaged<AudioEncoder>.fromOpaque(inUserData!)
                    .takeUnretainedValue()
                guard let pcm = encoder.inputBuffer else {
                    ioNumberDataPackets.pointee = 0
                    return -1
                }
                let bufferList = pcm.audioBufferList
                ioNumberDataPackets.pointee = pcm.frameLength
                ioData.pointee.mNumberBuffers = bufferList.pointee.mNumberBuffers
                withUnsafeMutablePointer(to: &ioData.pointee.mBuffers) { destPtr in
                    withUnsafePointer(to: bufferList.pointee.mBuffers) { srcPtr in
                        destPtr.pointee = srcPtr.pointee
                    }
                }
                encoder.inputBuffer = nil
                return noErr
            },
            Unmanaged.passUnretained(self).toOpaque(),
            &outputPacketCount,
            &outputBufferList,
            &outputPacketDescription
        )

        guard err == noErr, outputPacketCount > 0 else { return }
        let byteCount = Int(outputBufferList.mBuffers.mDataByteSize)
        onAAC?(Data(bytes: outputData, count: byteCount))
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }
}
