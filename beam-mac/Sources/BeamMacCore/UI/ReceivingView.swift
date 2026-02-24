import SwiftUI
import AppKit

/// Receiver-side view: borderless window showing the stream.
/// Wraps StreamView (NSView + AVSampleBufferDisplayLayer) and attaches input handling.
struct ReceivingView: View {
    let session: BeamSession

    var body: some View {
        ZStack {
            if let streamView = session.streamView {
                StreamViewRepresentable(streamView: streamView, session: session)
                    .ignoresSafeArea()
            } else {
                Color.black
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Waiting for stream…")
                        .foregroundStyle(.white)
                }
            }

            // Overlay: window title + disconnect button (top bar, auto-hides)
            VStack {
                HStack {
                    Text(session.windowTitle)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                    Text("from \(session.peerName)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button {
                        session.stop()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.5))

                Spacer()
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

// MARK: - NSViewRepresentable wrapper for StreamView

private struct StreamViewRepresentable: NSViewRepresentable {
    let streamView: StreamView
    let session: BeamSession

    func makeNSView(context: Context) -> StreamView {
        // Attach input handler once the view is in a window
        DispatchQueue.main.async {
            session.attachInputHandler(to: streamView)
        }
        // Enable mouse tracking
        streamView.window?.acceptsMouseMovedEvents = true
        return streamView
    }

    func updateNSView(_ nsView: StreamView, context: Context) {}
}
