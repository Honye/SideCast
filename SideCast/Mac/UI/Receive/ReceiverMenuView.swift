//
//  ReceiverMenuView.swift
//  SideCast
//
//  Menu bar popover in receive mode (FR-RECV-07): find a Mac, pair, see the connection,
//  set SideCast's volume on this Mac, disconnect.
//

#if os(macOS)
import SwiftUI

struct ReceiverMenuView: View {
    @Environment(ReceiverController.self) private var receiver
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SideCast")
                    .font(.headline)
                Spacer()
                Text("Receive mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if receiver.node.localNetworkDenied {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Local network access is off", systemImage: "wifi.exclamationmark")
                        .font(.callout.weight(.semibold))
                    Text("SideCast needs local network access to find your Mac. Turn it on in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings") { SystemSettingsLink.open(SystemSettingsLink.localNetwork) }
                        .controlSize(.small)
                }
            }
            if let error = receiver.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if receiver.pairingSession != nil {
                PairingCodeEntry()
            } else if let session = receiver.activeSession {
                ConnectedCard(session: session)
            } else {
                SenderList()
            }

            Divider()
            MenuFooter(openSettings: openSettings)
        }
        .padding()
        .frame(width: 340)
    }
}

private struct SenderList: View {
    @Environment(ReceiverController.self) private var receiver

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nearby Macs")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if receiver.senders.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Looking for Macs running SideCast…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(receiver.senders) { peer in
                SenderRow(peer: peer)
            }
            Text("This Mac appears on the other Mac as “\(receiver.identity.device.name)”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SenderRow: View {
    @Environment(ReceiverController.self) private var receiver
    let peer: DiscoveredPeer

    var body: some View {
        let status = receiver.status(for: peer.id)
        let paired = receiver.trustStore.peers.contains { $0.id == peer.id }
        let sameAccount = receiver.accountDirectory.containsDevice(id: peer.id)
            && !receiver.trustStore.revokedAccountDevices.contains(peer.id)
        HStack(spacing: 10) {
            Image(systemName: peer.device.platform.symbolName)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.device.name)
                Group {
                    if sameAccount {
                        Text("Same Apple ID")
                    } else if paired {
                        Text("Paired")
                    } else {
                        Text("Not paired yet")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if status == .connecting || status == .pairing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Connect") { receiver.connect(peer) }
                    .controlSize(.small)
            }
        }
    }
}

private struct ConnectedCard: View {
    @Environment(ReceiverController.self) private var receiver
    let session: PeerSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Connected to \(session.peer?.name ?? "")")
                        .font(.callout.weight(.semibold))
                    LinkLabel(link: receiver.link)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Group {
                        if let stream = receiver.currentStream {
                            Text(stream.codec == .opus ? "Low latency" : "High quality")
                        } else {
                            Text("Choose this Mac as an app's output on the other Mac.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: Bindable(receiver).volume, in: 0...1)
                    .accessibilityLabel(Text("SideCast volume"))
                Image(systemName: "speaker.wave.3.fill")
            }
            .foregroundStyle(.secondary)
            Button("Disconnect", role: .destructive) {
                receiver.disconnect()
            }
        }
    }
}

private struct PairingCodeEntry: View {
    @Environment(ReceiverController.self) private var receiver
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enter the code shown on \(receiver.pairingSession?.peer?.name ?? "your Mac")")
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            TextField("000000", text: $code)
                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onChange(of: code) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(HandshakeCrypto.pairingCodeLength))
                    if digits != newValue { code = digits }
                }
                .onSubmit(pair)
            HStack {
                Button("Cancel") { receiver.cancelPairing() }
                Spacer()
                if receiver.pairingSession?.state == .pairingVerifying {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Pair", action: pair)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.count != HandshakeCrypto.pairingCodeLength || receiver.pairingSession?.state != .pairingEnterCode)
            }
        }
        .onAppear { focused = true }
    }

    private func pair() {
        guard code.count == HandshakeCrypto.pairingCodeLength else { return }
        receiver.submitPairingCode(code)
    }
}
#endif
