import SwiftUI

/// Sender-side status view: shows "Beaming {window} to {device}" with a stop button.
struct BeamingView: View {
    let session: BeamSession

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.up.right.video.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Beaming")
                .font(.title2.bold())

            VStack(spacing: 4) {
                Text(session.windowTitle)
                    .font(.headline)
                Text("to \(session.peerName)")
                    .foregroundStyle(.secondary)
            }

            statusBadge

            Button("Stop Beam") {
                session.stop()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(40)
        .frame(minWidth: 320, minHeight: 300)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch session.state {
        case .connecting:
            Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.orange)
        case .active:
            Label("Live", systemImage: "circle.fill")
                .foregroundStyle(.green)
        case .stopping, .stopped:
            Label("Stopped", systemImage: "stop.circle.fill")
                .foregroundStyle(.secondary)
        case .idle:
            EmptyView()
        }
    }
}
