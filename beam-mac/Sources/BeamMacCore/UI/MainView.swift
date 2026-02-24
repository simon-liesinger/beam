import SwiftUI
import ScreenCaptureKit

public struct MainView: View {
    public init() {}
    @Environment(AppModel.self) private var model

    public var body: some View {
        if let session = model.activeSession {
            BeamingView(session: session)
        } else {
            windowPickerView
        }
    }

    private var windowPickerView: some View {
        @Bindable var model = model
        return List(selection: Binding(
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
                if let error = model.windowError {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Cannot list windows", systemImage: "exclamationmark.triangle")
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else if model.isLoadingWindows {
                    Label("Loading windows…", systemImage: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                } else if model.filteredWindows.isEmpty {
                    if model.searchText.isEmpty {
                        Label("No capturable windows found", systemImage: "macwindow.badge.plus")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("No matching windows", systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.filteredWindows, id: \.windowID) { window in
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
        .searchable(text: Binding(
            get: { model.searchText },
            set: { model.searchText = $0 }
        ), prompt: "Search windows or apps…")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(model.updateLabel) {
                    model.checkForUpdates()
                }
                .foregroundStyle(.secondary)
                .disabled(model.isCheckingUpdate)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await model.refreshWindows() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isLoadingWindows)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Beam") {
                    model.startBeam()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedPeer == nil || model.selectedWindow == nil)
            }
        }
        .navigationTitle("Beam")
        .frame(minWidth: 600, minHeight: 520)
        .onAppear {
            // When returning from BeamingView the window may still be at its narrow size.
            // Expand back to at least the picker's minimum width.
            if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible }) {
                if window.frame.width < 600 {
                    var frame = window.frame
                    frame.size.width = 600
                    window.setFrame(frame, display: true, animate: true)
                }
            }
        }
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
