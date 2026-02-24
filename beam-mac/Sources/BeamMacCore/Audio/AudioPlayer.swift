import AVFoundation

/// Plays decoded audio using AVAudioEngine.
/// Accepts interleaved Float32 PCM (from AudioDecoder) and converts to
/// non-interleaved for AVAudioEngine, which rejects interleaved format.
class AudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let playbackFormat: AVAudioFormat
    private let channels: Int

    init(sampleRate: Double = 48000, channels: UInt32 = 2) throws {
        self.channels = Int(channels)

        // AVAudioEngine requires standardFormat (non-interleaved)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                          channels: AVAudioChannelCount(channels)) else {
            throw AudioError.osstatus("AudioPlayer: failed to create format", -1)
        }
        playbackFormat = format

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
        try engine.start()
        playerNode.play()
    }

    /// Accepts interleaved Float32 PCM buffer, converts to non-interleaved, schedules.
    func play(interleavedBuffer: AVAudioPCMBuffer) {
        let frameCount = Int(interleavedBuffer.frameLength)
        guard let playBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat,
                                                 frameCapacity: interleavedBuffer.frameLength)
        else { return }
        playBuffer.frameLength = interleavedBuffer.frameLength

        let src = interleavedBuffer.audioBufferList.pointee.mBuffers.mData!
            .assumingMemoryBound(to: Float.self)
        for ch in 0..<channels {
            guard let dst = playBuffer.floatChannelData?[ch] else { continue }
            for f in 0..<frameCount {
                dst[f] = src[f * channels + ch]
            }
        }

        playerNode.scheduleBuffer(playBuffer)
    }

    func stop() {
        playerNode.stop()
        engine.stop()
    }
}
