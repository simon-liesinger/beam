import SwiftUI
import ScreenCaptureKit

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(
            get: { model.selectedWindow?.windowID },
            set: { id in model.selectedWindow = model.windows.first { $0.windowID == id } }
        )) {
            Section("Send To") {
                if model.peers.isEmpty {
                    Label("No devices found…", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.peers) { peer in
                        PeerRow(peer: peer, isSelected: model.selectedPeer?.id == peer.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedPeer = peer }
                    }
                }
            }

            Section {
                if model.isLoadingWindows {
                    Label("Loading windows…", systemImage: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                } else if model.windows.isEmpty {
                    Label("No capturable windows found", systemImage: "macwindow.badge.plus")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.windows, id: \.windowID) { window in
                        WindowRow(window: window, isSelected: model.selectedWindow?.windowID == window.windowID)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedWindow = window }
                    }
                }
            } header: {
                HStack {
                    Text("Select Window")
                    Spacer()
                    Button {
                        Task { await model.refreshWindows() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isLoadingWindows)
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Beam") {
                    // Wired up in Week 3 — streaming pipeline
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedPeer == nil || model.selectedWindow == nil)
            }
        }
        .navigationTitle("Beam")
        .frame(minWidth: 380, minHeight: 480)
    }
}

// MARK: - PeerRow

private struct PeerRow: View {
    let peer: PeerInfo
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: peer.platform == "android" ? "iphone" : "laptopcomputer")
                .foregroundStyle(isSelected ? .white : .accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                Text(peer.platform.capitalized)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.white)
                    .font(.caption.bold())
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.85) : Color.clear)
    }
}

// MARK: - WindowRow

private struct WindowRow: View {
    let window: SCWindow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // App icon via NSWorkspace
            if let pid = window.owningApplication?.processID,
               let app = NSRunningApplication(processIdentifier: pid_t(pid)),
               let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "macwindow")
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(window.title ?? "Untitled")
                    .lineLimit(1)
                    .fontWeight(isSelected ? .semibold : .regular)
                Text(window.owningApplication?.applicationName ?? "")
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.white)
                    .font(.caption.bold())
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.85) : Color.clear)
    }
}
