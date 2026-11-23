//
//  MenuBarView.swift
//  SideCast
//

#if os(macOS)
import SwiftUI

struct MenuBarView: View {
    @Environment(SenderController.self) private var sender
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SideCast")
                .font(.headline)

            DevicesSection()
            Divider()
            AppsSection()

            Divider()
            HStack {
                Button("Settings…", action: openSettings)
                Spacer()
                Button("Quit SideCast") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding()
        .frame(width: 340)
    }
}

private struct DevicesSection: View {
    @Environment(SenderController.self) private var sender

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Devices")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if sender.receivers.isEmpty {
                Text("Open SideCast on your iPad to see it here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(sender.receivers) { peer in
                ReceiverRow(peer: peer)
            }
        }
    }
}

private struct AppsSection: View {
    @Environment(SenderController.self) private var sender

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apps")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let error = sender.audioError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            if sender.visibleApps.isEmpty {
                Text("Apps that play sound appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(sender.visibleApps) { app in
                AppRowView(app: app)
            }
        }
    }
}

private struct ReceiverRow: View {
    @Environment(SenderController.self) private var sender
    let peer: DiscoveredPeer

    var body: some View {
        let status = sender.status(for: peer.id)
        HStack {
            Image(systemName: peer.device.platform.symbolName)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.device.name)
                StatusText(status: status)
            }
            Spacer()
            if status == .connected {
                Picker(selection: Binding(
                    get: { sender.audioMode(for: peer.id) },
                    set: { sender.setAudioMode($0, for: peer.id) }
                )) {
                    Text("Low latency").tag(AudioMode.lowLatency)
                    Text("High quality").tag(AudioMode.highQuality)
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            switch status {
            case .connected, .connecting, .pairing:
                Button("Disconnect") { sender.disconnect(peer.id) }
            case .available, .failed:
                Button("Connect") { sender.connect(peer) }
            }
        }
    }
}

struct StatusText: View {
    let status: LinkStatus

    var body: some View {
        Group {
            switch status {
            case .available: Text("Not connected")
            case .connecting: Text("Connecting…")
            case .pairing: Text("Waiting for pairing code…")
            case .connected: Text("Connected").foregroundStyle(.green)
            case .failed(let message): Text(message).foregroundStyle(.red)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
#endif
