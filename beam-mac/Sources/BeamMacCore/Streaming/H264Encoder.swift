import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Wraps VTCompressionSession for hardware H.264 encoding.
/// Outputs raw NAL units (SPS/PPS sent before each keyframe).
/// Uses per-frame outputHandler variant — session-level C callbacks are painful in Swift.
class H264Encoder {
    private var session: VTCompressionSession?
    private var frameCount: Int = 0

    /// Called for each NAL unit produced (SPS, PPS, IDR slices, non-IDR slices).
    /// Parameters: (nalData, isKeyframe, rtpTimestamp in 90kHz units)
    var onNAL: ((Data, Bool, UInt32) -> Void)?

    let width: Int32
    let height: Int32

    init(width: Int32, height: Int32, fps: Int32 = 30, bitrate: Int = 8_000_000) {
        self.width = width
        self.height = height

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let sess = session else {
            fatalError("H264Encoder: failed to create compression session: \(status)")
        }

        self.session = sess

        // Low-latency real-time encoding
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: bitrate as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: 60 as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: fps as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxFrameDelayCount,
                             value: 0 as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(sess)
    }

    func encode(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard let session = session else { return }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: timestamp,
            duration: CMTime(value: 1, timescale: 30),
            frameProperties: nil,
            infoFlagsOut: nil,
            outputHandler: { [weak self] status, flags, sampleBuffer in
                self?.handleEncodedFrame(status: status, sampleBuffer: sampleBuffer)
            }
        )

        if status != noErr {
            print("H264Encoder: encode error \(status)")
        }
    }

    /// Request a keyframe on the next encode call.
    func forceKeyframe() {
        // Set on next encode via frame properties
        // (caller can also just call encode with properties — keeping this simple for now)
    }

    private func handleEncodedFrame(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer = sampleBuffer else { return }

        frameCount += 1

        let isKeyframe = !sampleBuffer.sampleAttachments.first.map {
            ($0[.notSync] as? Bool) ?? false
        }!

        // Convert PTS to 90kHz RTP timestamp
        let pts = sampleBuffer.presentationTimeStamp
        let rtpTimestamp = UInt32(CMTimeConvertScale(pts, timescale: 90000, method: .default).value
                                  & 0xFFFFFFFF)

        // Send SPS/PPS before keyframes
        if isKeyframe, let formatDesc = sampleBuffer.formatDescription {
            sendParameterSets(formatDesc: formatDesc, timestamp: rtpTimestamp)
        }

        // Extract NAL units from AVCC format: [4-byte length][NAL data]...
        guard let dataBuffer = sampleBuffer.dataBuffer else { return }

        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let blockStatus = CMBlockBufferGetDataPointer(
            dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength, dataPointerOut: &dataPointer
        )
        guard blockStatus == noErr, let ptr = dataPointer else { return }

        var offset = 0
        while offset < totalLength - 4 {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, ptr + offset, 4)
            nalLength = CFSwapInt32BigToHost(nalLength)
            offset += 4

            guard nalLength > 0, offset + Int(nalLength) <= totalLength else { break }

            let nalData = Data(bytes: ptr + offset, count: Int(nalLength))
            onNAL?(nalData, isKeyframe, rtpTimestamp)
            offset += Int(nalLength)
        }
    }

    private func sendParameterSets(formatDesc: CMFormatDescription, timestamp: UInt32) {
        var count: Int = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        )

        for i in 0..<count {
            var paramPtr: UnsafePointer<UInt8>?
            var paramSize: Int = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, parameterSetIndex: i,
                parameterSetPointerOut: &paramPtr, parameterSetSizeOut: &paramSize,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let ptr = paramPtr else { continue }

            let paramData = Data(bytes: ptr, count: paramSize)
            onNAL?(paramData, true, timestamp)
        }
    }

    deinit {
        if let session = session {
            VTCompressionSessionInvalidate(session)
        }
    }
}
