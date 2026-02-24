import Foundation
import AudioToolbox
import AVFoundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import Darwin

// ============================================================================
// MARK: - Audio Capture + Mute Spike
// ============================================================================
//
// Captures per-app audio via ScreenCaptureKit and optionally mutes via
// Core Audio Process Taps. Encodes to AAC, sends over UDP, receives, decodes,
// and plays.
//
// Usage:
//   .build/debug/AudioCaptureSpike send [app-name] [--mute]  # capture + encode + UDP send
//   .build/debug/AudioCaptureSpike receive                     # UDP receive + decode + play
//   .build/debug/AudioCaptureSpike list                        # list apps with windows
//
// Architecture:
//   - ScreenCaptureKit: per-app audio capture (uses Screen Recording permission)
//   - Core Audio Process Tap: mute only (uses System Audio Recording permission)
//   - AAC encode/decode via AudioToolbox
//   - UDP transport with timestamps for latency measurement

setlinebuf(stdout)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// ============================================================================
// MARK: - Core Audio Helpers (for mute-only tap)
// ============================================================================

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = kAudioObjectUnknown
    var isValid: Bool { self != Self.unknown }

    static func readProcessList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(Self.system, &address, 0, nil, &dataSize)
        guard err == noErr else { throw "readProcessList size failed: \(err)" }
        var list = [AudioObjectID](repeating: .unknown, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(Self.system, &address, 0, nil, &dataSize, &list)
        guard err == noErr else { throw "readProcessList data failed: \(err)" }
        return list
    }

    static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceID = AudioDeviceID.unknown
        let err = AudioObjectGetPropertyData(Self.system, &address, 0, nil, &dataSize, &deviceID)
        guard err == noErr else { throw "readDefaultSystemOutputDevice failed: \(err)" }
        return deviceID
    }

    func readDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        var uid: CFString = "" as CFString
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &uid)
        guard err == noErr else { throw "readDeviceUID failed: \(err)" }
        return uid as String
    }

    func readTapStreamDescription() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var desc = AudioStreamBasicDescription()
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &desc)
        guard err == noErr else { throw "readTapStreamDescription failed: \(err)" }
        return desc
    }

    func readIsRunning() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &value)
        return err == noErr && value == 1
    }

    func readPID() throws -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        var pid: pid_t = -1
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &pid)
        guard err == noErr else { throw "readPID failed: \(err)" }
        return pid
    }
}

extension String: @retroactive LocalizedError {
    public var errorDescription: String? { self }
}

// ============================================================================
// MARK: - Mute-Only Process Tap (Core Audio)
// ============================================================================

@available(macOS 14.2, *)
class MuteProcessTap {
    private var tapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "mute-tap", qos: .userInteractive)

    /// Creates a mute-only tap for the given audio process object ID.
    /// This silences the app's audio locally. We must start an IO proc on the
    /// aggregate device for the tap to actually intercept audio.
    func mute(processObjectID: AudioObjectID) throws {
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .mutedWhenTapped

        var newTapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard err == noErr else { throw "AudioHardwareCreateProcessTap failed: \(err)" }
        self.tapID = newTapID

        // Need an aggregate device to activate the tap
        let systemOutputID = try AudioObjectID.readDefaultSystemOutputDevice()
        let outputUID = try systemOutputID.readDeviceUID()

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BeamMuteTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
        guard err == noErr else { throw "AudioHardwareCreateAggregateDevice failed: \(err)" }

        // CRITICAL: Must create an IO proc and start the device for the tap to work.
        // Without this, the tap is created but never actually intercepts audio.
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, queue) { _, inInputData, inInputTime, outOutputData, inOutputTime in
            // Discard captured audio - we only want the mute side-effect
        }
        guard err == noErr else { throw "AudioDeviceCreateIOProcIDWithBlock failed: \(err)" }
        self.deviceProcID = procID

        err = AudioDeviceStart(aggregateDeviceID, procID)
        guard err == noErr else { throw "AudioDeviceStart failed: \(err)" }

        print("  Mute tap active (tap #\(tapID), aggregate #\(aggregateDeviceID), IO running)")
    }

    func unmute() {
        if aggregateDeviceID.isValid {
            AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if let deviceProcID {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
                self.deviceProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }

    deinit { unmute() }
}

// ============================================================================
// MARK: - Global State (prevent ARC dealloc)
// ============================================================================

var gStream: SCStream?
var gDelegate: AudioStreamDelegate?
var gMuteTaps: [Any] = []

class AudioStreamDelegate: NSObject, SCStreamOutput, SCStreamDelegate {
    var audioHandler: ((CMSampleBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            audioHandler?(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("  SCK stream error: \(error)")
    }
}

// ============================================================================
// MARK: - AAC Encoder
// ============================================================================

class AACEncoder {
    private var converter: AudioConverterRef?
    let inputFormat: AudioStreamBasicDescription
    let outputFormat: AudioStreamBasicDescription
    private var inputBuffer: AVAudioPCMBuffer?

    init(sampleRate: Float64, channels: UInt32) throws {
        // PCM input format (Float32, interleaved)
        self.inputFormat = AudioStreamBasicDescription(
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

        // AAC-LC output format
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
        self.outputFormat = outFormat

        var inFormat = inputFormat
        var conv: AudioConverterRef?
        let err = AudioConverterNew(&inFormat, &outFormat, &conv)
        guard err == noErr, let conv else { throw "AudioConverterNew failed: \(err)" }
        self.converter = conv

        var bitrate: UInt32 = channels > 1 ? 128000 : 64000
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate)
        print("  AAC encoder: \(sampleRate)Hz \(channels)ch -> AAC \(bitrate/1000)kbps")
    }

    func encode(pcmBuffer: AVAudioPCMBuffer) -> Data? {
        guard let converter else { return nil }
        self.inputBuffer = pcmBuffer

        let maxOutputSize: UInt32 = 4096
        let outputData = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(maxOutputSize))
        defer { outputData.deallocate() }

        var outputBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: inputFormat.mChannelsPerFrame,
                mDataByteSize: maxOutputSize,
                mData: outputData
            )
        )

        var outputPacketCount: UInt32 = 1
        var outputPacketDescription = AudioStreamPacketDescription()

        let err = AudioConverterFillComplexBuffer(
            converter,
            { (_, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
                let encoder = Unmanaged<AACEncoder>.fromOpaque(inUserData!).takeUnretainedValue()
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

        guard err == noErr, outputPacketCount > 0 else { return nil }
        let byteCount = Int(outputBufferList.mBuffers.mDataByteSize)
        return Data(bytes: outputData, count: byteCount)
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }
}

// ============================================================================
// MARK: - AAC Decoder
// ============================================================================

class AACDecoder {
    private var converter: AudioConverterRef?
    let inputFormat: AudioStreamBasicDescription
    let outputFormat: AudioStreamBasicDescription
    private var inputData: Data?
    private var packetDescription = AudioStreamPacketDescription()

    init(sampleRate: Float64, channels: UInt32) throws {
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
        self.inputFormat = inFormat

        var outFormat = AudioStreamBasicDescription(
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

        var conv: AudioConverterRef?
        let err = AudioConverterNew(&inFormat, &outFormat, &conv)
        guard err == noErr, let conv else { throw "AAC decoder AudioConverterNew failed: \(err)" }
        self.converter = conv
        print("  AAC decoder: AAC -> \(sampleRate)Hz \(channels)ch Float32")
    }

    func decode(aacData: Data) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        var desc = outputFormat
        guard let format = AVAudioFormat(streamDescription: &desc) else { return nil }

        self.inputData = aacData
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else { return nil }

        var outputBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: outputFormat.mChannelsPerFrame,
                mDataByteSize: UInt32(1024 * outputFormat.mBytesPerFrame),
                mData: pcmBuffer.audioBufferList.pointee.mBuffers.mData
            )
        )

        var outputPacketCount: UInt32 = 1024

        let err = AudioConverterFillComplexBuffer(
            converter,
            { (_, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
                let decoder = Unmanaged<AACDecoder>.fromOpaque(inUserData!).takeUnretainedValue()
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
                    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: rawBuf.baseAddress!)
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

        guard err == noErr, outputPacketCount > 0 else { return nil }
        pcmBuffer.frameLength = outputPacketCount
        return pcmBuffer
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }
}

// ============================================================================
// MARK: - UDP Transport
// ============================================================================

let kAudioPort: UInt16 = 19877
let kHeaderSize = 12  // 4 (seq) + 8 (timestamp)

class UDPAudioSender {
    private let socket: Int32
    private let dest: sockaddr_in
    private var sequence: UInt32 = 0

    init(host: String = "127.0.0.1", port: UInt16 = kAudioPort) throws {
        socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard socket >= 0 else { throw "socket() failed" }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        self.dest = addr
    }

    func send(aacData: Data) {
        var packet = Data(capacity: kHeaderSize + aacData.count)
        var seq = sequence.bigEndian
        packet.append(Data(bytes: &seq, count: 4))
        sequence += 1
        var ts = mach_absolute_time().bigEndian
        packet.append(Data(bytes: &ts, count: 8))
        packet.append(aacData)

        packet.withUnsafeBytes { rawBuf in
            var addr = dest
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(socket, rawBuf.baseAddress, rawBuf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    deinit { close(socket) }
}

class UDPAudioReceiver {
    private let socketFD: Int32

    init(port: UInt16 = kAudioPort) throws {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw "socket() failed: \(errno)" }
        self.socketFD = fd
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0)  // INADDR_ANY
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw "bind() failed: \(errno)" }
    }

    func receive() -> (seq: UInt32, timestamp: UInt64, aacData: Data)? {
        // Use poll() with timeout to check readability
        var pfd = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pfd, 1, 5000) // 5 second timeout
        if pollResult == 0 {
            print("  [RECV] poll() timed out (5s) - no data on fd \(socketFD)")
            return nil
        } else if pollResult < 0 {
            print("  [RECV] poll() error: \(errno)")
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.recv(socketFD, &buffer, buffer.count, 0)
        if n <= 0 {
            print("  [RECV] recv returned \(n), errno=\(errno)")
        }
        guard n > kHeaderSize else { return nil }
        let data = Data(buffer[0..<n])
        var seqBE: UInt32 = 0
        var tsBE: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &seqBE) { data.copyBytes(to: $0, from: 0..<4) }
        _ = withUnsafeMutableBytes(of: &tsBE) { data.copyBytes(to: $0, from: 4..<12) }
        let seq = UInt32(bigEndian: seqBE)
        let ts = UInt64(bigEndian: tsBE)
        let aacData = data.subdata(in: kHeaderSize..<n)
        return (seq, ts, aacData)
    }

    deinit { Darwin.close(socketFD) }
}

// ============================================================================
// MARK: - Latency Tracker
// ============================================================================

class LatencyTracker {
    private var timebaseInfo = mach_timebase_info_data_t()
    private var samples = [Double]()
    private let lock = NSLock()

    init() { mach_timebase_info(&timebaseInfo) }

    func record(sendTimestamp: UInt64) {
        let now = mach_absolute_time()
        let elapsed = now - sendTimestamp
        let nanos = Double(elapsed) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
        let ms = nanos / 1_000_000
        lock.lock()
        samples.append(ms)
        lock.unlock()
    }

    func report() -> (avg: Double, min: Double, max: Double, count: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return nil }
        let avg = samples.reduce(0, +) / Double(samples.count)
        return (avg, samples.min()!, samples.max()!, samples.count)
    }

    func reset() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }
}

// ============================================================================
// MARK: - Sender Mode (ScreenCaptureKit audio + optional Core Audio mute)
// ============================================================================

func runSender(appName: String?, shouldMute: Bool) async throws {
    print("\n=== AUDIO CAPTURE SPIKE - SENDER ===\n")

    // 1. Find the target app via ScreenCaptureKit
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

    let targetApp: SCRunningApplication
    if let appName {
        let lowered = appName.lowercased()
        // Prefer exact match, then contains match, skip widget/service processes
        guard let found = content.applications.first(where: {
            $0.applicationName.lowercased() == lowered
        }) ?? content.applications.first(where: {
            $0.applicationName.lowercased().contains(lowered) && !$0.applicationName.contains("Service")
        }) ?? content.applications.first(where: {
            $0.applicationName.lowercased().contains(lowered)
        }) else {
            print("ERROR: App '\(appName)' not found. Available apps:")
            for a in content.applications where !(a.applicationName ).isEmpty {
                print("  - \(a.applicationName ) (PID \(a.processID))")
            }
            exit(1)
        }
        targetApp = found
    } else {
        print("ERROR: Please specify an app name.")
        print("Usage: AudioCaptureSpike send <app-name> [--mute]")
        exit(1)
    }

    print("Target: \(targetApp.applicationName ) (PID \(targetApp.processID))")

    // 2. Optionally mute via Core Audio Process Tap
    // Mute needs to target the audio-producing process, which for Chrome is a Helper subprocess
    if shouldMute {
        if #available(macOS 14.2, *) {
            print("\nSetting up mute tap...")
            do {
                let objectIDs = try AudioObjectID.readProcessList()
                // Find PIDs belonging to the target app (main process + child helpers)
                // For Chrome: main PID + Chrome Helper processes (audio, renderer, etc.)
                let targetPID = targetApp.processID
                let targetBundle = targetApp.bundleIdentifier
                // Get all PIDs for apps with matching bundle ID
                let matchingApps = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundle)
                var targetPIDs = Set(matchingApps.map { $0.processIdentifier })
                targetPIDs.insert(targetPID)

                // Also find child processes (Chrome Helpers are children of main Chrome)
                // Use process group: children share the same PGID as parent
                for objID in objectIDs {
                    if let pid = try? objID.readPID() {
                        // Check if this process is a child of the target app
                        // by checking if its parent PID matches
                        var kinfo = kinfo_proc()
                        var size = MemoryLayout<kinfo_proc>.size
                        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
                        if sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0 {
                            let ppid = kinfo.kp_eproc.e_ppid
                            if targetPIDs.contains(ppid) {
                                targetPIDs.insert(pid)
                            }
                        }
                    }
                }
                print("  Target PIDs: \(targetPIDs.sorted())")

                var mutedAny = false
                for objID in objectIDs {
                    guard objID.readIsRunning() else { continue }
                    guard let pid = try? objID.readPID(), targetPIDs.contains(pid) else { continue }
                    let tap = MuteProcessTap()
                    do {
                        try tap.mute(processObjectID: objID)
                        gMuteTaps.append(tap)  // keep ALL taps alive
                        mutedAny = true
                        print("  Muted audio process object #\(objID) (PID \(pid))")
                    } catch {
                        print("  Failed to mute #\(objID) (PID \(pid)): \(error)")
                    }
                }
                if !mutedAny {
                    print("  WARNING: No active audio processes found to mute for \(targetApp.applicationName).")
                }
            } catch {
                print("  WARNING: Mute failed: \(error). Continuing without mute.")
            }
        } else {
            print("  WARNING: Mute requires macOS 14.2+. Continuing without mute.")
        }
    }

    // 3. Configure ScreenCaptureKit for audio capture
    print("\nStarting ScreenCaptureKit audio capture...")

    let filter = SCContentFilter(display: content.displays.first!,
                                  including: [targetApp],
                                  exceptingWindows: [])

    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = true
    config.sampleRate = 48000
    config.channelCount = 2

    // Minimal video (SCK requires it even for audio-only)
    config.width = 2
    config.height = 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

    // 4. Create AAC encoder
    print("Creating AAC encoder...")
    let encoder = try AACEncoder(sampleRate: 48000, channels: 2)

    // 5. Create UDP sender
    print("Creating UDP sender (port \(kAudioPort))...")
    let sender = try UDPAudioSender()

    // 6. Stats
    var packetsSent: UInt64 = 0
    var totalBytes: UInt64 = 0
    var lastReportTime = CFAbsoluteTimeGetCurrent()
    var packetsInInterval: UInt64 = 0
    var audioCallbacks: UInt64 = 0
    var debugCount = 0

    // 7. Start SCK stream with audio handler
    let audioQueue = DispatchQueue(label: "sck-audio", qos: .userInteractive)

    let delegate = AudioStreamDelegate()
    gDelegate = delegate  // prevent ARC

    // PCM format for the encoder
    var pcmDesc = AudioStreamBasicDescription(
        mSampleRate: 48000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8,
        mFramesPerPacket: 1,
        mBytesPerFrame: 8,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    let pcmFormat = AVAudioFormat(streamDescription: &pcmDesc)!

    delegate.audioHandler = { sampleBuffer in
        audioCallbacks += 1

        guard sampleBuffer.formatDescription != nil else { return }

        if audioCallbacks == 1 {
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(sampleBuffer.formatDescription!)?.pointee {
                print("  Audio: \(asbd.mSampleRate)Hz \(asbd.mChannelsPerFrame)ch \(asbd.mBitsPerChannel)bit, \(sampleBuffer.numSamples) frames/callback")
            }
        }

        // Get needed buffer list size (SCK delivers non-interleaved = 2 AudioBuffers)
        var bufferListSizeNeeded: Int = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )

        let ablMemory = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferListSizeNeeded)
        defer { ablMemory.deallocate() }
        let ablPtr = UnsafeMutableRawPointer(ablMemory).bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        // SCK delivers non-interleaved audio. Interleave for AAC encoder.
        let numBuffers = Int(ablPtr.pointee.mNumberBuffers)
        let frameCount = UInt32(sampleBuffer.numSamples)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        let channels = min(numBuffers, 2)
        let dstPtr = pcmBuffer.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        for ch in 0..<channels {
            let srcBuf = UnsafeMutableAudioBufferListPointer(ablPtr)[ch]
            guard let srcData = srcBuf.mData else { continue }
            let src = srcData.assumingMemoryBound(to: Float.self)
            for f in 0..<Int(frameCount) {
                dstPtr[f * 2 + ch] = src[f]
            }
        }

        // Encode to AAC
        guard let aacData = encoder.encode(pcmBuffer: pcmBuffer) else { return }

        // Send over UDP
        sender.send(aacData: aacData)

        packetsSent += 1
        totalBytes += UInt64(aacData.count)
        packetsInInterval += 1

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastReportTime >= 2.0 {
            let pps = Double(packetsInInterval) / (now - lastReportTime)
            let kbps = Double(totalBytes) * 8.0 / (now - lastReportTime) / 1000.0
            print("Sent: \(packetsSent) pkts | \(String(format: "%.1f", pps)) pkt/s | \(String(format: "%.1f", kbps)) kbps | last AAC: \(aacData.count)B | callbacks: \(audioCallbacks)")
            packetsInInterval = 0
            lastReportTime = now
            totalBytes = 0
        }
    }

    let scStream = SCStream(filter: filter, configuration: config, delegate: delegate)
    try scStream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: audioQueue)
    try scStream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: audioQueue)
    try await scStream.startCapture()
    gStream = scStream  // prevent ARC

    signal(SIGINT) { _ in
        print("\n\nStopping SCK stream...")
        Task {
            try? await gStream?.stopCapture()
            gStream = nil
            gDelegate = nil
            gMuteTaps = []
            print("Clean shutdown.")
            exit(0)
        }
    }

    print("\nCapturing audio from \"\(targetApp.applicationName)\" (mute=\(shouldMute)).")
    print("Press Ctrl+C to stop.\n")
}

// ============================================================================
// MARK: - Receiver Mode
// ============================================================================

func runReceiver() throws {
    print("\n=== AUDIO CAPTURE SPIKE - RECEIVER ===\n")

    let sampleRate: Float64 = 48000
    let channels: UInt32 = 2
    print("Expecting: \(Int(sampleRate))Hz \(channels)ch AAC")

    print("\nCreating AAC decoder...")
    let decoder = try AACDecoder(sampleRate: sampleRate, channels: channels)

    print("Creating audio engine...")
    let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()
    engine.attach(playerNode)

    // AVAudioEngine requires standard (non-interleaved) format on macOS
    guard let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) else {
        throw "Failed to create AVAudioFormat for playback"
    }
    print("  Playback format: \(playbackFormat)")

    engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
    try engine.start()
    playerNode.play()
    print("  Audio engine started")

    print("Listening on UDP port \(kAudioPort)...\n")
    let receiver = try UDPAudioReceiver()

    let latencyTracker = LatencyTracker()
    var packetsReceived: UInt64 = 0
    var lastReportTime = CFAbsoluteTimeGetCurrent()
    var packetsInInterval: UInt64 = 0
    var decodeFails: UInt64 = 0

    signal(SIGINT) { _ in
        print("\n\nStopping...")
        exit(0)
    }

    print("Playing received audio. Press Ctrl+C to stop.\n")
    fflush(stdout)

    // Run recv loop on main thread (blocking)
    while true {
        guard let (_, timestamp, aacData) = receiver.receive() else { continue }

        if packetsReceived == 0 {
            print("  First audio packet received (\(aacData.count) bytes)")
            fflush(stdout)
        }
        packetsReceived += 1
        packetsInInterval += 1
        latencyTracker.record(sendTimestamp: timestamp)

        // Decode AAC to interleaved PCM
        guard let interleavedBuffer = decoder.decode(aacData: aacData) else {
            decodeFails += 1
            continue
        }

        // Convert interleaved to non-interleaved for AVAudioEngine
        guard let playBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: interleavedBuffer.frameLength) else {
            decodeFails += 1
            continue
        }
        playBuffer.frameLength = interleavedBuffer.frameLength
        let frameCount = Int(interleavedBuffer.frameLength)
        let src = interleavedBuffer.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        for ch in 0..<Int(channels) {
            guard let dst = playBuffer.floatChannelData?[ch] else { continue }
            for f in 0..<frameCount {
                dst[f] = src[f * Int(channels) + ch]
            }
        }

        playerNode.scheduleBuffer(playBuffer)

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastReportTime >= 2.0 {
            let pps = Double(packetsInInterval) / (now - lastReportTime)
            if let lat = latencyTracker.report() {
                print("Recv: \(packetsReceived) pkts | \(String(format: "%.1f", pps)) pkt/s | latency: \(String(format: "%.1f", lat.avg))ms avg [\(String(format: "%.1f", lat.min))-\(String(format: "%.1f", lat.max))ms] | fails: \(decodeFails)")
            } else {
                print("Recv: \(packetsReceived) pkts | \(String(format: "%.1f", pps)) pkt/s | fails: \(decodeFails)")
            }
            fflush(stdout)
            packetsInInterval = 0
            lastReportTime = now
            latencyTracker.reset()
        }
    }
}

// ============================================================================
// MARK: - List Mode
// ============================================================================

func runList() async throws {
    print("\n=== APPS (via ScreenCaptureKit) ===\n")
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    let apps = content.applications.filter { !($0.applicationName ).isEmpty }
    for a in apps.sorted(by: { ($0.applicationName ) < ($1.applicationName ) }) {
        print("  \(a.applicationName) (PID \(a.processID))")
    }
    print("\nTotal: \(apps.count) apps")
}

// ============================================================================
// MARK: - Main
// ============================================================================

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "list"

if mode == "receive" {
    // Receiver runs on main thread directly (no Task) because it blocks in recv()
    do {
        try runReceiver()
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
} else {
    Task {
        do {
            switch mode {
            case "send":
                let appName = args.count > 2 ? args[2] : nil
                let shouldMute = args.contains("--mute")
                try await runSender(appName: appName, shouldMute: shouldMute)
            case "list":
                try await runList()
                exit(0)
            default:
                print("Usage:")
                print("  AudioCaptureSpike list                    # list apps")
                print("  AudioCaptureSpike send <app-name> [--mute] # capture + encode + send")
                print("  AudioCaptureSpike receive                  # receive + decode + play")
                exit(1)
            }
        } catch {
            print("ERROR: \(error)")
            exit(1)
        }
    }
    dispatchMain()
}
