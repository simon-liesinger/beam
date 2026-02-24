import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Wraps SCStream to capture a single window's frames.
/// Uses SCContentFilter(desktopIndependentWindow:) so capture continues even when
/// the window is moved to the virtual hidden display.
class WindowCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?

    /// Called on the capture queue for every delivered frame.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private(set) var isCapturing = false

    // MARK: - Start / Stop

    func startCapture(window: SCWindow, width: Int, height: Int) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 3

        // Retry up to 3 times — ScreenCaptureKit daemon can be in a bad state
        // after an unclean shutdown, returning error -3805.
        for attempt in 1...3 {
            do {
                stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream!.addStreamOutput(self, type: .screen,
                                            sampleHandlerQueue: DispatchQueue(label: "beam.capture"))
                try await stream!.startCapture()
                isCapturing = true
                return
            } catch {
                print("WindowCapturer: attempt \(attempt) failed: \(error.localizedDescription)")
                stream = nil
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } else {
                    throw error
                }
            }
        }
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        isCapturing = false
    }

    /// Synchronous stop for use in signal handlers / deinit.
    func stopSync() {
        guard let s = stream else { return }
        let sem = DispatchSemaphore(value: 0)
        Task {
            try? await s.stopCapture()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2.0)
        stream = nil
        isCapturing = false
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let pts = sampleBuffer.presentationTimeStamp
        onFrame?(pixelBuffer, pts)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("WindowCapturer: stream stopped with error: \(error.localizedDescription)")
        isCapturing = false
    }
}
