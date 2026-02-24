import Foundation
import AudioToolbox
import AVFoundation

/// Decodes AAC packets to interleaved Float32 PCM using AudioToolbox.
class AudioDecoder {
    private var converter: AudioConverterRef?
    private var inputData: Data?
    private var packetDescription = AudioStreamPacketDescription()
    private let channels: UInt32

    /// Called for each decoded PCM buffer (interleaved Float32, 1024 frames).
    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let outputFormat: AudioStreamBasicDescription

    init(sampleRate: Float64 = 48000, channels: UInt32 = 2) throws {
        self.channels = channels

        var inFormat = AudioStreamBasicDescription(
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

        let outFormat = AudioStreamBasicDescription(
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
        self.outputFormat = outFormat

        var outFmt = outFormat
        var conv: AudioConverterRef?
        let err = AudioConverterNew(&inFormat, &outFmt, &conv)
        guard err == noErr, let c = conv else {
            throw AudioError.osstatus("AudioDecoder: AudioConverterNew", err)
        }
        converter = c
    }

    func decode(aacData: Data) {
        guard let converter = converter else { return }

        var desc = outputFormat
        guard let format = AVAudioFormat(streamDescription: &desc) else { return }

        inputData = aacData
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: 1024) else { return }

        var outputBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channels,
                mDataByteSize: UInt32(1024 * outputFormat.mBytesPerFrame),
                mData: pcmBuffer.audioBufferList.pointee.mBuffers.mData
            )
        )

        var outputPacketCount: UInt32 = 1024

        let err = AudioConverterFillComplexBuffer(
            converter,
            { (_, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
                let decoder = Unmanaged<AudioDecoder>.fromOpaque(inUserData!)
                    .takeUnretainedValue()
                guard let data = decoder.inputData else {
                    ioNumberDataPackets.pointee = 0
                    return -1
                }
                ioNumberDataPackets.pointee = 1
                if let outDesc = outDataPacketDescription {
                    decoder.packetDescription = AudioStreamPacketDescription(
                        mStartOffset: 0,
                        mVariableFramesInPacket: 0,
                        mDataByteSize: UInt32(data.count)
                    )
                    outDesc.pointee = withUnsafeMutablePointer(to: &decoder.packetDescription) { $0 }
                }
                data.withUnsafeBytes { rawBuf in
                    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(
                        mutating: rawBuf.baseAddress!)
                    ioData.pointee.mBuffers.mDataByteSize = UInt32(data.count)
                    ioData.pointee.mNumberBuffers = 1
                }
                decoder.inputData = nil
                return noErr
            },
            Unmanaged.passUnretained(self).toOpaque(),
            &outputPacketCount,
            &outputBufferList,
            nil
        )

        guard err == noErr, outputPacketCount > 0 else { return }
        pcmBuffer.frameLength = outputPacketCount
        onPCMBuffer?(pcmBuffer)
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }
}
