import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Captures per-app audio via ScreenCaptureKit and optionally mutes via
/// Core Audio Process Tap. Delivers interleaved Float32 PCM at 48kHz stereo.
///
/// Architecture:
///   - ScreenCaptureKit: per-app audio capture (Screen Recording permission)
///   - Core Audio Process Tap: mute only (System Audio Recording permission)
///   SCK delivers non-interleaved audio; we interleave before calling onPCMBuffer.
class AudioCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?

    /// Interleaved Float32 stereo 48kHz PCM, ~960 frames per callback (~47/sec).
    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var muteTap: AnyObject?  // MuteProcessTap (macOS 14.2+), type-erased for availability

    // Interleaved PCM format for the encoder
    private static let pcmDesc = AudioStreamBasicDescription(
        mSampleRate: 48000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8,     // 4 bytes × 2 channels
        mFramesPerPacket: 1,
        mBytesPerFrame: 8,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    private let pcmFormat: AVAudioFormat = {
        var desc = pcmDesc
        return AVAudioFormat(streamDescription: &desc)!
    }()

    // MARK: - Mute blacklist

    /// Apps that use a single audio process for all windows (e.g. Chrome Helper).
    /// These are NOT muted when beamed if they have other un-beamed windows,
    /// because muting would silence audio from those windows too.
    static let muteBlacklist: Set<String> = [
        "com.google.Chrome",
    ]

    /// Returns true if the app's audio should be muted when beaming.
    static func shouldMute(bundleID: String, appWindowCount: Int, beamedWindowCount: Int) -> Bool {
        if muteBlacklist.contains(bundleID) && appWindowCount > beamedWindowCount {
            print("AudioCapturer: skipping mute for \(bundleID) — "
                  + "\(appWindowCount) windows open, only \(beamedWindowCount) beamed")
            return false
        }
        return true
    }

    // MARK: - Start / Stop

    /// Start audio capture for the given app. The display is needed for SCContentFilter.
    /// If `mute` is true (and shouldMute passes), the app's local audio is silenced.
    func start(app: SCRunningApplication, display: SCDisplay, mute: Bool) async throws {
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        // Minimal video — SCK requires it even for audio-only
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let audioQueue = DispatchQueue(label: "beam.audio.capture", qos: .userInteractive)
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream!.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream!.addStreamOutput(self, type: .screen, sampleHandlerQueue: audioQueue)
        try await stream!.startCapture()

        // Set up mute tap
        if mute {
            if #available(macOS 14.2, *) {
                let tap = MuteProcessTap()
                tap.muteApp(app: app)
                muteTap = tap
            } else {
                print("AudioCapturer: mute requires macOS 14.2+")
            }
        }

        print("AudioCapturer: capturing \(app.applicationName) (mute=\(mute))")
    }

    func stop() async {
        if #available(macOS 14.2, *) {
            (muteTap as? MuteProcessTap)?.unmute()
        }
        muteTap = nil
        try? await stream?.stopCapture()
        stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.formatDescription != nil else { return }

        // Get the audio buffer list (SCK delivers non-interleaved: 2 AudioBuffers for stereo)
        var bufferListSize: Int = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil
        )

        let ablMemory = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferListSize)
        defer { ablMemory.deallocate() }
        let ablPtr = UnsafeMutableRawPointer(ablMemory)
            .bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr, bufferListSize: bufferListSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        // Interleave non-interleaved channels into a single buffer
        let numBuffers = Int(ablPtr.pointee.mNumberBuffers)
        let frameCount = UInt32(sampleBuffer.numSamples)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                                frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        let channels = min(numBuffers, 2)
        let dstPtr = pcmBuffer.audioBufferList.pointee.mBuffers.mData!
            .assumingMemoryBound(to: Float.self)
        for ch in 0..<channels {
            let srcBuf = UnsafeMutableAudioBufferListPointer(ablPtr)[ch]
            guard let srcData = srcBuf.mData else { continue }
            let src = srcData.assumingMemoryBound(to: Float.self)
            for f in 0..<Int(frameCount) {
                dstPtr[f * 2 + ch] = src[f]
            }
        }

        onPCMBuffer?(pcmBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("AudioCapturer: stream error: \(error.localizedDescription)")
    }
}

// MARK: - Core Audio Process Tap (mute-only)

/// Mutes an app's local audio output using Core Audio Process Tap.
/// Critical: must create an IO proc and call AudioDeviceStart on the aggregate
/// device, or the tap is created but never actually intercepts audio.
@available(macOS 14.2, *)
class MuteProcessTap {
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var deviceProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "beam.mute-tap", qos: .userInteractive)

    func muteApp(app: SCRunningApplication) {
        do {
            // Find audio process objects belonging to the target app
            let objectIDs = try readProcessList()
            let targetPID = app.processID
            let targetBundle = app.bundleIdentifier

            // Collect all PIDs: main process + helper subprocesses
            let matchingApps = NSRunningApplication.runningApplications(
                withBundleIdentifier: targetBundle)
            var targetPIDs = Set(matchingApps.map { $0.processIdentifier })
            targetPIDs.insert(targetPID)

            // Find child processes (Chrome Helpers are children of main Chrome)
            for objID in objectIDs {
                if let pid = try? readPID(objID) {
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

            var mutedAny = false
            for objID in objectIDs {
                guard isRunning(objID),
                      let pid = try? readPID(objID),
                      targetPIDs.contains(pid) else { continue }
                do {
                    try createMuteTap(processObjectID: objID)
                    mutedAny = true
                    print("MuteProcessTap: muted audio object #\(objID) (PID \(pid))")
                } catch {
                    print("MuteProcessTap: failed to mute #\(objID): \(error)")
                }
            }
            if !mutedAny {
                print("MuteProcessTap: no active audio processes found for \(app.applicationName)")
            }
        } catch {
            print("MuteProcessTap: \(error)")
        }
    }

    func unmute() {
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if let procID = deviceProcID {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
                deviceProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    deinit { unmute() }

    // MARK: - Private

    private func createMuteTap(processObjectID: AudioObjectID) throws {
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .mutedWhenTapped

        var newTapID: AudioObjectID = kAudioObjectUnknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard err == noErr else { throw AudioError.osstatus("CreateProcessTap", err) }
        tapID = newTapID

        // Aggregate device activates the tap
        let systemOutputID = try readDefaultSystemOutput()
        let outputUID = try readDeviceUID(systemOutputID)

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
        guard err == noErr else { throw AudioError.osstatus("CreateAggregateDevice", err) }

        // CRITICAL: IO proc must be running for the tap to intercept audio
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregateDeviceID, queue
        ) { _, _, _, _, _ in }
        guard err == noErr else { throw AudioError.osstatus("CreateIOProcID", err) }
        deviceProcID = procID

        err = AudioDeviceStart(aggregateDeviceID, procID)
        guard err == noErr else { throw AudioError.osstatus("AudioDeviceStart", err) }
    }

    // MARK: - Core Audio property reads

    private func readProcessList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard err == noErr else { throw AudioError.osstatus("readProcessList size", err) }
        var list = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &list)
        guard err == noErr else { throw AudioError.osstatus("readProcessList data", err) }
        return list
    }

    private func readDefaultSystemOutput() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
        guard err == noErr else { throw AudioError.osstatus("readDefaultSystemOutput", err) }
        return deviceID
    }

    private func readDeviceUID(_ deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard err == noErr else { throw AudioError.osstatus("readDeviceUID size", err) }
        var uid: Unmanaged<CFString>?
        err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &uid)
        guard err == noErr, let uidRef = uid else {
            throw AudioError.osstatus("readDeviceUID", err)
        }
        return uidRef.takeRetainedValue() as String
    }

    private func readPID(_ objID: AudioObjectID) throws -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        var pid: pid_t = -1
        let err = AudioObjectGetPropertyData(objID, &address, 0, nil, &dataSize, &pid)
        guard err == noErr else { throw AudioError.osstatus("readPID", err) }
        return pid
    }

    private func isRunning(_ objID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let err = AudioObjectGetPropertyData(objID, &address, 0, nil, &dataSize, &value)
        return err == noErr && value == 1
    }
}

enum AudioError: Error {
    case osstatus(String, OSStatus)
}
