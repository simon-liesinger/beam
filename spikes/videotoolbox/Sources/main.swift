import Foundation
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import Network
import ScreenCaptureKit
import VideoToolbox

// Disable stdout buffering so print statements appear immediately
setbuf(stdout, nil)

// Initialize GUI connection to the window server
let app = NSApplication.shared
app.setActivationPolicy(.regular)

// MARK: - Constants

let udpPort: UInt16 = 9876
let maxUDPPayload = 1400  // Stay under typical MTU
let targetFPS: Int32 = 30
let targetBitrate: Int = 8_000_000  // 8 Mbps

// MARK: - RTP-like Packet Header (12 bytes)
//
// Bytes 0-1:  sequence number (UInt16, big-endian)
// Bytes 2-5:  timestamp (UInt32, big-endian) - presentation time in 90kHz units
// Byte  6:    flags (bit 0 = keyframe, bit 1 = start-of-NAL, bit 2 = end-of-NAL)
// Byte  7:    reserved
// Bytes 8-9:  fragment index (UInt16, big-endian) - fragment number within NAL
// Bytes 10-11: fragment count (UInt16, big-endian) - total fragments for this NAL

let headerSize = 12

struct PacketFlags {
    static let keyframe:    UInt8 = 0x01
    static let startOfNAL:  UInt8 = 0x02
    static let endOfNAL:    UInt8 = 0x04
}

func makeHeader(seq: UInt16, timestamp: UInt32, flags: UInt8, fragIndex: UInt16, fragCount: UInt16) -> Data {
    var header = Data(count: headerSize)
    header[0] = UInt8(seq >> 8)
    header[1] = UInt8(seq & 0xFF)
    header[2] = UInt8(timestamp >> 24)
    header[3] = UInt8((timestamp >> 16) & 0xFF)
    header[4] = UInt8((timestamp >> 8) & 0xFF)
    header[5] = UInt8(timestamp & 0xFF)
    header[6] = flags
    header[7] = 0
    header[8] = UInt8(fragIndex >> 8)
    header[9] = UInt8(fragIndex & 0xFF)
    header[10] = UInt8(fragCount >> 8)
    header[11] = UInt8(fragCount & 0xFF)
    return header
}

func parseHeader(_ data: Data) -> (seq: UInt16, timestamp: UInt32, flags: UInt8, fragIndex: UInt16, fragCount: UInt16)? {
    guard data.count >= headerSize else { return nil }
    let seq = UInt16(data[0]) << 8 | UInt16(data[1])
    let timestamp = UInt32(data[2]) << 24 | UInt32(data[3]) << 16 | UInt32(data[4]) << 8 | UInt32(data[5])
    let flags = data[6]
    let fragIndex = UInt16(data[8]) << 8 | UInt16(data[9])
    let fragCount = UInt16(data[10]) << 8 | UInt16(data[11])
    return (seq, timestamp, flags, fragIndex, fragCount)
}

// MARK: - H.264 Encoder

class H264Encoder {
    private var session: VTCompressionSession?
    private let sendNAL: (Data, Bool, UInt32) -> Void  // (nalData, isKeyframe, timestamp)
    private var frameCount: Int = 0

    init(width: Int32, height: Int32, sendNAL: @escaping (Data, Bool, UInt32) -> Void) {
        self.sendNAL = sendNAL

        // Create session with nil callback - we'll use per-frame outputHandler
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
            fatalError("Failed to create compression session: \(status)")
        }

        // Configure for low-latency real-time encoding
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: targetBitrate as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: targetFPS as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(sess)
        print("H264Encoder: created (\(width)x\(height), \(targetBitrate/1_000_000)Mbps, \(targetFPS)fps)")
    }

    func encode(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard let session = session else { return }

        // Use per-frame outputHandler variant
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: timestamp,
            duration: CMTime(value: 1, timescale: targetFPS),
            frameProperties: nil,
            infoFlagsOut: nil,
            outputHandler: { [weak self] status, flags, sampleBuffer in
                self?.handleEncodedFrame(status: status, flags: flags, sampleBuffer: sampleBuffer)
            }
        )

        if status != noErr {
            print("Encode error: \(status)")
        }
    }

    private func handleEncodedFrame(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer = sampleBuffer else { return }

        frameCount += 1

        let isKeyframe = !sampleBuffer.sampleAttachments.first.map {
            ($0[.notSync] as? Bool) ?? false
        }!

        // Convert presentation timestamp to 90kHz RTP timestamp
        let pts = sampleBuffer.presentationTimeStamp
        let rtpTimestamp = UInt32(CMTimeConvertScale(pts, timescale: 90000, method: .default).value & 0xFFFFFFFF)

        // For keyframes, extract and send SPS/PPS first
        if isKeyframe {
            if let formatDesc = sampleBuffer.formatDescription {
                sendParameterSets(formatDesc: formatDesc, timestamp: rtpTimestamp)
            }
        }

        // Extract NAL units from the sample buffer
        // VideoToolbox produces AVCC format: [4-byte length][NAL data][4-byte length][NAL data]...
        guard let dataBuffer = sampleBuffer.dataBuffer else { return }

        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let blockStatus = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard blockStatus == noErr, let ptr = dataPointer else { return }

        var offset = 0
        while offset < totalLength - 4 {
            // Read 4-byte NAL length (big-endian)
            var nalLength: UInt32 = 0
            memcpy(&nalLength, ptr + offset, 4)
            nalLength = CFSwapInt32BigToHost(nalLength)
            offset += 4

            guard nalLength > 0, offset + Int(nalLength) <= totalLength else { break }

            let nalData = Data(bytes: ptr + offset, count: Int(nalLength))
            sendNAL(nalData, isKeyframe, rtpTimestamp)
            offset += Int(nalLength)
        }
    }

    private func sendParameterSets(formatDesc: CMFormatDescription, timestamp: UInt32) {
        var count: Int = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)

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
            sendNAL(paramData, true, timestamp)
        }
    }

    deinit {
        if let session = session {
            VTCompressionSessionInvalidate(session)
        }
    }
}

// MARK: - H.264 Decoder

class H264Decoder {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?
    private var frameCount: Int = 0
    let onFrame: (CVPixelBuffer, CMTime) -> Void

    init(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.onFrame = onFrame
        print("H264Decoder: ready (will create session on first SPS/PPS)")
    }

    func decodeNAL(_ nalData: Data, timestamp: UInt32) {
        guard !nalData.isEmpty else { return }

        let nalType = nalData[0] & 0x1F

        // SPS (7) and PPS (8) - store and recreate session
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

        // IDR (5) or non-IDR (1) - decode
        guard let session = session, let formatDescription = formatDescription,
              (nalType == 1 || nalType == 5) else { return }

        // Wrap NAL data in AVCC format (4-byte length prefix)
        var nalLength = CFSwapInt32HostToBig(UInt32(nalData.count))

        var avccData = Data(bytes: &nalLength, count: 4)
        avccData.append(nalData)

        // Create CMBlockBuffer from the data
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
                CMBlockBufferReplaceDataBytes(with: ptr, blockBuffer: bb, offsetIntoDestination: 0, dataLength: dataCount)
            }
        }
        guard let bb = blockBuffer else { return }

        // Create CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataCount
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: targetFPS),
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
                self?.onFrame(pb, pts)
            }
        )

        if status != noErr {
            print("Decode error: \(status)")
        }
    }

    private func tryCreateSession() {
        guard let sps = spsData, let pps = ppsData else { return }

        // Create format description from SPS + PPS
        // Must keep pointers valid during the call
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
            print("Failed to create format description: \(status)")
            return
        }

        // Check if format changed (compare dimensions manually)
        if let existing = formatDescription {
            let oldDims = CMVideoFormatDescriptionGetDimensions(existing)
            let newDims = CMVideoFormatDescriptionGetDimensions(fd)
            if oldDims.width == newDims.width && oldDims.height == newDims.height {
                return  // Same format, keep existing session
            }
        }

        // Invalidate old session
        if let oldSession = session {
            VTDecompressionSessionInvalidate(oldSession)
        }

        formatDescription = fd
        let dims = CMVideoFormatDescriptionGetDimensions(fd)

        // Create decompression session (no callback - we use per-frame handler in decodeNAL)
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
            print("Failed to create decompression session: \(createStatus)")
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

// MARK: - UDP Sender

class UDPSender {
    private let connection: NWConnection
    private var sequenceNumber: UInt16 = 0
    var packetsSent: Int = 0
    var bytesSent: Int = 0

    init(port: UInt16) {
        connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )
        connection.start(queue: DispatchQueue(label: "udp.sender"))
        print("UDPSender: targeting 127.0.0.1:\(port)")
    }

    func sendNAL(data: Data, isKeyframe: Bool, timestamp: UInt32) {
        let maxPayload = maxUDPPayload - headerSize
        let fragCount = UInt16((data.count + maxPayload - 1) / maxPayload)

        var offset = 0
        var fragIndex: UInt16 = 0

        while offset < data.count {
            let chunkSize = min(maxPayload, data.count - offset)
            let chunk = data[offset..<offset + chunkSize]

            var flags: UInt8 = 0
            if isKeyframe { flags |= PacketFlags.keyframe }
            if fragIndex == 0 { flags |= PacketFlags.startOfNAL }
            if fragIndex == fragCount - 1 { flags |= PacketFlags.endOfNAL }

            var packet = makeHeader(seq: sequenceNumber, timestamp: timestamp, flags: flags, fragIndex: fragIndex, fragCount: fragCount)
            packet.append(contentsOf: chunk)

            connection.send(content: packet, completion: .contentProcessed { _ in })

            sequenceNumber &+= 1
            packetsSent += 1
            bytesSent += packet.count
            offset += chunkSize
            fragIndex += 1
        }
    }
}

// MARK: - UDP Receiver + Frame Reassembler

class UDPReceiver {
    private var socket: Int32 = -1
    private let queue = DispatchQueue(label: "udp.receiver")
    var packetsReceived: Int = 0
    var nalUnitsAssembled: Int = 0

    // Reassembly: accumulate fragments keyed by timestamp
    private var fragments: [UInt32: [UInt16: Data]] = [:]  // timestamp -> [fragIndex: data]
    private var fragCounts: [UInt32: UInt16] = [:]  // timestamp -> expected fragment count
    private var fragFlags: [UInt32: UInt8] = [:]    // timestamp -> flags from first fragment

    let onNAL: (Data, Bool, UInt32) -> Void  // (nalData, isKeyframe, timestamp)

    init(port: UInt16, onNAL: @escaping (Data, Bool, UInt32) -> Void) {
        self.onNAL = onNAL

        // Use raw BSD sockets for reliable UDP receive
        socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard socket >= 0 else { fatalError("Failed to create UDP socket") }

        var reuseAddr: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socket, SOL_SOCKET, SO_REUSEPORT, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { fatalError("Failed to bind UDP socket: \(errno)") }

        // Start receive loop on background thread
        queue.async { [weak self] in
            self?.receiveLoop()
        }

        print("UDPReceiver: listening on port \(port)")
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 2000)
        while socket >= 0 {
            let bytesRead = recv(socket, &buffer, buffer.count, 0)
            guard bytesRead > 0 else {
                if bytesRead < 0 && errno != EAGAIN { break }
                continue
            }
            let data = Data(buffer[..<bytesRead])
            processPacket(data)
        }
    }

    private func processPacket(_ data: Data) {
        guard let header = parseHeader(data) else { return }
        packetsReceived += 1

        let payload = data[headerSize...]

        // Store fragment
        if fragments[header.timestamp] == nil {
            fragments[header.timestamp] = [:]
        }
        fragments[header.timestamp]![header.fragIndex] = Data(payload)
        fragCounts[header.timestamp] = header.fragCount
        if header.flags & PacketFlags.startOfNAL != 0 {
            fragFlags[header.timestamp] = header.flags
        }

        // Check if all fragments received for this NAL
        if let frags = fragments[header.timestamp],
           let count = fragCounts[header.timestamp],
           frags.count == Int(count) {

            // Reassemble NAL in order
            var nalData = Data()
            for i in 0..<count {
                if let frag = frags[i] {
                    nalData.append(frag)
                }
            }

            let isKeyframe = (fragFlags[header.timestamp] ?? header.flags) & PacketFlags.keyframe != 0

            // Clean up
            fragments.removeValue(forKey: header.timestamp)
            fragCounts.removeValue(forKey: header.timestamp)
            fragFlags.removeValue(forKey: header.timestamp)

            nalUnitsAssembled += 1
            onNAL(nalData, isKeyframe, header.timestamp)
        }

        // Garbage collect old incomplete NALs (more than 1 second old in RTP time)
        let cutoff = header.timestamp &- 90000
        for ts in fragments.keys {
            if ts < cutoff && ts < header.timestamp {
                fragments.removeValue(forKey: ts)
                fragCounts.removeValue(forKey: ts)
                fragFlags.removeValue(forKey: ts)
            }
        }
    }
}

// MARK: - Renderer (NSWindow + AVSampleBufferDisplayLayer)

class StreamRenderer {
    let window: NSWindow
    let displayLayer: AVSampleBufferDisplayLayer
    var framesRendered: Int = 0

    init(width: Int, height: Int) {
        // Create borderless window
        let frame = NSRect(x: 100, y: 100, width: width, height: height)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Beam - Decoded Stream"
        window.isReleasedWhenClosed = false

        // Create display layer
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.frame = NSRect(x: 0, y: 0, width: width, height: height)
        displayLayer.videoGravity = .resizeAspect

        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.addSublayer(displayLayer)
        window.contentView = view

        // Auto-resize layer with window
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        window.makeKeyAndOrderFront(nil)
        print("StreamRenderer: window created (\(width)x\(height))")
    }

    func renderFrame(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        // Create format description
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard let fd = formatDesc else { return }

        // Create sample buffer
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: targetFPS),
            presentationTimeStamp: timestamp,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard let sb = sampleBuffer else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.displayLayer.status == .failed {
                self.displayLayer.flush()
            }
            self.displayLayer.enqueue(sb)
            self.framesRendered += 1
        }
    }
}

// MARK: - ScreenCaptureKit Capture (reused from spike 1)

class WindowCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    var frameCount: Int = 0
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    func startCapture(window: SCWindow, width: Int, height: Int) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: targetFPS)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 3

        // Retry loop - ScreenCaptureKit daemon can be in a bad state after unclean shutdown
        for attempt in 1...3 {
            do {
                stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream!.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
                print("Capture: starting SCStream (attempt \(attempt))...")
                try await stream!.startCapture()
                print("Capture: SCStream started successfully")
                return
            } catch {
                print("Capture: attempt \(attempt) failed: \(error)")
                stream = nil
                if attempt < 3 {
                    print("Capture: waiting 2s before retry...")
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } else {
                    throw error
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pixelBuffer = sampleBuffer.imageBuffer else {
            // Log when we get samples without image buffers
            if frameCount == 0 {
                print("Capture: got sample buffer but no imageBuffer (type: \(type))")
            }
            return
        }
        frameCount += 1
        if frameCount == 1 {
            print("Capture: first frame received!")
        }
        onFrame?(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    // SCStreamDelegate - error callback
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Capture ERROR: stream stopped with error: \(error)")
    }

    func stop() async {
        try? await stream?.stopCapture()
    }

    func stopSync() {
        guard let s = stream else { return }
        let sem = DispatchSemaphore(value: 0)
        Task {
            try? await s.stopCapture()
            sem.signal()
        }
        sem.wait(timeout: .now() + 2.0)
        stream = nil
    }
}

// MARK: - Latency Tracker

class LatencyTracker {
    private var encodeTimes: [UInt32: CFAbsoluteTime] = [:]  // timestamp -> encode start time
    private var samples: [Double] = []
    private let lock = NSLock()

    func markEncodeStart(timestamp: UInt32) {
        lock.lock()
        encodeTimes[timestamp] = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    func markDecodeEnd(timestamp: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        guard let start = encodeTimes.removeValue(forKey: timestamp) else { return }
        let latency = (CFAbsoluteTimeGetCurrent() - start) * 1000.0  // ms
        samples.append(latency)

        // Keep only last 100 samples
        if samples.count > 100 { samples.removeFirst() }

        // Clean old entries
        let cutoff = CFAbsoluteTimeGetCurrent() - 2.0
        encodeTimes = encodeTimes.filter { $0.value > cutoff }
    }

    func report() -> (avg: Double, min: Double, max: Double, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return (0, 0, 0, 0) }
        let avg = samples.reduce(0, +) / Double(samples.count)
        return (avg, samples.min()!, samples.max()!, samples.count)
    }
}

// MARK: - Window Listing

func listWindows() async throws -> [SCWindow] {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    return content.windows.filter { window in
        guard let title = window.title, !title.isEmpty else { return false }
        guard window.frame.width > 100 && window.frame.height > 100 else { return false }
        return true
    }
}

// MARK: - Main Pipeline

func runPipeline(window: SCWindow) async throws {
    let width = Int(window.frame.width)
    let height = Int(window.frame.height)
    let appName = window.owningApplication?.applicationName ?? "Unknown"
    print("\nPipeline: capturing '\(appName) - \(window.title ?? "?")' at \(width)x\(height)")

    let latencyTracker = LatencyTracker()

    // 1. Create UDP sender
    let sender = UDPSender(port: udpPort)

    // 2. Create encoder
    let encoder = H264Encoder(width: Int32(width), height: Int32(height)) { nalData, isKeyframe, timestamp in
        sender.sendNAL(data: nalData, isKeyframe: isKeyframe, timestamp: timestamp)
    }

    // 3. Create decoder + renderer (must be on main thread)
    let rendererSem = DispatchSemaphore(value: 0)
    var renderer: StreamRenderer!
    DispatchQueue.main.async {
        renderer = StreamRenderer(width: width, height: height)
        rendererSem.signal()
    }
    rendererSem.wait()

    let decoder = H264Decoder { pixelBuffer, pts in
        let rtpTs = UInt32(CMTimeConvertScale(pts, timescale: 90000, method: .default).value & 0xFFFFFFFF)
        latencyTracker.markDecodeEnd(timestamp: rtpTs)
        renderer.renderFrame(pixelBuffer: pixelBuffer, timestamp: pts)
    }

    // 4. Create UDP receiver
    let receiver = UDPReceiver(port: udpPort) { nalData, isKeyframe, timestamp in
        decoder.decodeNAL(nalData, timestamp: timestamp)
    }

    // 5. Create capturer and wire up
    let capturer = WindowCapturer()
    capturer.onFrame = { pixelBuffer, pts in
        let rtpTs = UInt32(CMTimeConvertScale(pts, timescale: 90000, method: .default).value & 0xFFFFFFFF)
        latencyTracker.markEncodeStart(timestamp: rtpTs)
        encoder.encode(pixelBuffer: pixelBuffer, timestamp: pts)
    }

    print("Starting capture pipeline...\n")
    try await capturer.startCapture(window: window, width: width, height: height)

    print("Pipeline running. Press Ctrl+C to stop.\n")

    // Keep all pipeline objects alive by storing them globally
    pipelineRetainer = [capturer, encoder, sender, decoder, receiver, renderer, latencyTracker] as [AnyObject]

    // Stats reporting on a background thread (DispatchSource timers can get released)
    DispatchQueue.global().async {
        while true {
            Thread.sleep(forTimeInterval: 3.0)
            let lat = latencyTracker.report()
            let renderedFPS = Double(renderer.framesRendered) / 3.0
            print("Capture: \(capturer.frameCount) frames | "
                + "Sent: \(sender.packetsSent) pkts (\(sender.bytesSent / 1024) KB) | "
                + "Recv: \(receiver.packetsReceived) pkts, \(receiver.nalUnitsAssembled) NALs | "
                + "Rendered: \(renderer.framesRendered) (\(String(format: "%.1f", renderedFPS)) fps) | "
                + "Latency: \(String(format: "%.1f", lat.avg))ms avg "
                + "[\(String(format: "%.1f", lat.min))-\(String(format: "%.1f", lat.max))ms]")
            renderer.framesRendered = 0
        }
    }
}

// Global storage to keep pipeline objects alive after runPipeline returns
var pipelineRetainer: [AnyObject] = []

// MARK: - Entry Point

let args = CommandLine.arguments

func printUsage() {
    print("Usage:")
    print("  VideoToolboxSpike --list               List available windows")
    print("  VideoToolboxSpike --capture N           Capture window N")
    print("  VideoToolboxSpike                       Interactive mode")
}

// Launch on a background thread so the main thread can run the NSApp event loop
DispatchQueue.global().async {
    // Wrap in a Task for async/await
    Task {
        do {
            print("=== Beam VideoToolbox Spike ===\n")

            if args.contains("--help") {
                printUsage()
                exit(0)
            }

            if args.contains("--list") {
                let windows = try await listWindows()
                if windows.isEmpty {
                    print("No capturable windows found.")
                    exit(1)
                }
                for (i, window) in windows.enumerated() {
                    let appName = window.owningApplication?.applicationName ?? "Unknown"
                    let title = window.title ?? "Untitled"
                    let size = "\(Int(window.frame.width))x\(Int(window.frame.height))"
                    print("[\(i)] \(appName) - \(title) (\(size))")
                }
                exit(0)
            }

            if let captureIdx = args.firstIndex(of: "--capture"),
               captureIdx + 1 < args.count,
               let windowIdx = Int(args[captureIdx + 1]) {
                let windows = try await listWindows()
                guard windowIdx >= 0 && windowIdx < windows.count else {
                    print("Window index out of range")
                    exit(1)
                }
                try await runPipeline(window: windows[windowIdx])
                return  // NSApp.run() keeps us alive
            }

            // Interactive mode
            let windows = try await listWindows()
            if windows.isEmpty {
                print("No capturable windows found.")
                exit(1)
            }

            print("Available windows:\n")
            for (i, window) in windows.enumerated() {
                let appName = window.owningApplication?.applicationName ?? "Unknown"
                let title = window.title ?? "Untitled"
                let size = "\(Int(window.frame.width))x\(Int(window.frame.height))"
                print("  [\(i)] \(appName) - \(title) (\(size))")
            }

            print("\nEnter window number (or Enter for [0]): ", terminator: "")
            fflush(stdout)
            let input = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            let index = Int(input) ?? 0

            guard index >= 0 && index < windows.count else {
                print("Invalid selection.")
                exit(1)
            }

            try await runPipeline(window: windows[index])

        } catch let error as NSError where error.code == -3801 {
            print("\nScreen Recording permission required.")
            print("Grant access in: System Settings > Privacy & Security > Screen Recording")
            exit(1)
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}

// Handle Ctrl+C - clean up stream before exiting
signal(SIGINT) { _ in
    print("\nStopping pipeline...")
    // Stop any active SCStream to avoid daemon -3805 errors on next run
    for obj in pipelineRetainer {
        if let capturer = obj as? WindowCapturer {
            capturer.stopSync()
        }
    }
    // Give the stream a moment to clean up
    Thread.sleep(forTimeInterval: 0.5)
    print("Pipeline stopped.")
    exit(0)
}

// Run the main event loop (required for NSWindow, MainActor, etc.)
app.run()
