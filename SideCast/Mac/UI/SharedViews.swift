//
//  SharedViews.swift
//  SideCast
//
//  Pieces used by both the menu bar and the settings window.
//

#if os(macOS)
import SwiftUI

/// One nearby receiver: status, audio mode, connect / disconnect.
struct ReceiverRow: View {
    @Environment(SenderController.self) private var sender
    let device: DeviceInfo
    /// Nil when the receiver is connected but not currently discovered.
    let peer: DiscoveredPeer?

    var body: some View {
        let status = sender.status(for: device.id)
        HStack(spacing: 8) {
            Image(systemName: device.platform.symbolName)
                .frame(width: 20)
                .foregroundStyle(status == .connected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(device.name)
                        .lineLimit(1)
                    if status == .connected && sender.isPremium(receiver: device.id) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                            .help(Text("Premium"))
                    }
                }
                HStack(spacing: 6) {
                    StatusText(status: status)
                    if status == .connected, let link = sender.links[device.id] {
                        LinkLabel(link: link)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            Spacer(minLength: 4)
            if status == .connected {
                Picker(selection: Binding(
                    get: { sender.audioMode(for: device.id) },
                    set: { sender.setAudioMode($0, for: device.id) }
                )) {
                    Text("Low latency").tag(AudioMode.lowLatency)
                    Text("High quality").tag(AudioMode.highQuality)
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .accessibilityLabel(Text("Audio mode"))
            }
            if status == .connected {
                MirrorMenu(receiverID: device.id)
            }
            switch status {
            case .connected, .connecting, .pairing:
                Button("Disconnect") { sender.disconnect(device.id) }
                    .controlSize(.small)
            case .available, .failed:
                if let peer {
                    Button("Connect") { sender.connect(peer) }
                        .controlSize(.small)
                }
            }
        }
    }
}

/// Screen mirroring for one connected receiver (FR-SCREEN-01): pick a display, or stop.
struct MirrorMenu: View {
    @Environment(SenderController.self) private var sender
    let receiverID: UUID

    var body: some View {
        let current = sender.mirroredDisplay(for: receiverID)
        Menu {
            ForEach(MirrorDisplays.available) { display in
                Toggle(isOn: Binding(
                    get: { current == display.id },
                    set: { on in
                        if on {
                            sender.startMirroring(receiverID, display: display.id)
                        } else {
                            sender.stopMirroring(receiverID)
                        }
                    }
                )) {
                    Text("Mirror \(display.name)")
                }
            }
            if current != nil {
                Divider()
                Button("Stop Mirroring") { sender.stopMirroring(receiverID) }
            }
        } label: {
            Image(systemName: current == nil ? "rectangle.on.rectangle" : "rectangle.inset.filled.on.rectangle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .controlSize(.small)
        .help(current.map { Text("Mirroring \(MirrorDisplays.name(of: $0))") } ?? Text("Mirror screen"))
        .accessibilityLabel(Text("Screen mirroring"))
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
        .lineLimit(2)
    }
}

/// Receivers to list: discovered ones plus connected ones that are not discovered.
extension SenderController {
    var receiverRows: [(device: DeviceInfo, peer: DiscoveredPeer?)] {
        var rows = receivers.map { (device: $0.device, peer: Optional($0)) }
        for device in connectedReceivers where !rows.contains(where: { $0.device.id == device.id }) {
            rows.append((device: device, peer: nil))
        }
        return rows
    }
}

extension SenderController {
    var hasWarnings: Bool {
        node.localNetworkDenied || audioError != nil || capturedSilenceSuspected || screenError != nil || inputPermissionNeeded
    }
}

/// Problems the user can fix: missing permissions, capture errors (FR-PERM-02).
struct WarningsView: View {
    @Environment(SenderController.self) private var sender

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if sender.node.localNetworkDenied {
                Warning(
                    text: Text("SideCast can't find your devices because local network access is off."),
                    action: Text("Open Settings"),
                    url: SystemSettingsLink.localNetwork
                )
            }
            if let error = sender.screenError {
                Warning(text: Text(error), action: Text("Open Settings"), url: SystemSettingsLink.screenCapture)
            }
            if sender.inputPermissionNeeded {
                Warning(
                    text: Text("To use touch control from your devices, allow SideCast in Accessibility settings."),
                    action: Text("Open Settings"),
                    url: SystemSettingsLink.accessibility
                )
            }
            if let error = sender.audioError {
                Warning(text: Text(error), action: Text("Open Settings"), url: SystemSettingsLink.audioCapture)
            } else if sender.capturedSilenceSuspected {
                Warning(
                    text: Text("No sound is coming from the apps SideCast controls. If they are playing, allow SideCast to record system audio."),
                    action: Text("Open Settings"),
                    url: SystemSettingsLink.audioCapture
                )
            }
        }
    }

    private struct Warning: View {
        let text: Text
        let action: Text
        let url: URL

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Label { text } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button { SystemSettingsLink.open(url) } label: { action }
                    .controlSize(.small)
            }
        }
    }
}
#endif
