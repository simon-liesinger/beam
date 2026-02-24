import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Wraps VTDecompressionSession for hardware H.264 decoding.
/// Feed raw NAL units (SPS, PPS, IDR, non-IDR) — session is created
/// automatically when SPS+PPS are both received.
class H264Decoder {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?
    private var frameCount: Int = 0

    /// Called for each decoded frame. (pixelBuffer, presentationTimeStamp)
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    func decodeNAL(_ nalData: Data, timestamp: UInt32) {
        guard !nalData.isEmpty else { return }

        let nalType = nalData[0] & 0x1F

        // SPS (7) / PPS (8) — store and recreate session if needed
        if nalType == 7 {
            spsData = nalData
            tryCreateSession()
            return
        }
        if nalType == 8 {
            ppsData = nalData
            tryCreateSession()
            return
        }

        // IDR (5) or non-IDR (1) — decode
        guard let session = session, let formatDescription = formatDescription,
              (nalType == 1 || nalType == 5) else { return }

        // Wrap NAL in AVCC format (4-byte length prefix)
        var nalLength = CFSwapInt32HostToBig(UInt32(nalData.count))
        var avccData = Data(bytes: &nalLength, count: 4)
        avccData.append(nalData)

        // Create CMBlockBuffer
        var blockBuffer: CMBlockBuffer?
        let dataCount = avccData.count
        avccData.withUnsafeMutableBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress else { return }
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: dataCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            if let bb = blockBuffer {
                CMBlockBufferReplaceDataBytes(
                    with: ptr, blockBuffer: bb,
                    offsetIntoDestination: 0, dataLength: dataCount
                )
            }
        }
        guard let bb = blockBuffer else { return }

        // Create CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataCount
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: CMTimeValue(timestamp), timescale: 90000),
            decodeTimeStamp: .invalid
        )

        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard let sb = sampleBuffer else { return }

        // Decode with per-frame completion handler
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sb,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil,
            completionHandler: { [weak self] status, flags, imageBuffer, taggedBuffers, pts, duration in
                guard status == noErr, let pb = imageBuffer else { return }
                self?.frameCount += 1
                self?.onFrame?(pb, pts)
            }
        )

        if status != noErr {
            print("H264Decoder: decode error \(status)")
        }
    }

    private func tryCreateSession() {
        guard let sps = spsData, let pps = ppsData else { return }

        // Create format description from SPS + PPS
        var formatDesc: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                let spsBase = spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let ppsBase = ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                var paramSets = [spsBase, ppsBase]
                var paramSizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &paramSets,
                    parameterSetSizes: &paramSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
            }
        }

        guard status == noErr, let fd = formatDesc else {
            print("H264Decoder: failed to create format description: \(status)")
            return
        }

        // Skip if dimensions haven't changed (keep existing session)
        if let existing = formatDescription {
            let oldDims = CMVideoFormatDescriptionGetDimensions(existing)
            let newDims = CMVideoFormatDescriptionGetDimensions(fd)
            if oldDims.width == newDims.width && oldDims.height == newDims.height {
                return
            }
        }

        // Invalidate old session
        if let oldSession = session {
            VTDecompressionSessionInvalidate(oldSession)
        }

        formatDescription = fd
        let dims = CMVideoFormatDescriptionGetDimensions(fd)

        // Create decompression session
        let destAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]

        var newSession: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fd,
            decoderSpecification: nil,
            imageBufferAttributes: destAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )

        guard createStatus == noErr, let s = newSession else {
            print("H264Decoder: failed to create decompression session: \(createStatus)")
            return
        }

        session = s
        print("H264Decoder: session created (\(dims.width)x\(dims.height))")
    }

    deinit {
        if let session = session {
            VTDecompressionSessionInvalidate(session)
        }
    }
}
