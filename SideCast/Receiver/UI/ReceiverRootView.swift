//
//  ReceiverRootView.swift
//  SideCast
//

#if !os(macOS)
import SwiftUI

struct ReceiverRootView: View {
    @Environment(ReceiverController.self) private var receiver
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .overlay {
                if let mirror = receiver.mirror {
                    MirrorScreen(mirror: mirror)
                }
            }
            // In the background the system stops drawing; the Mac pauses meanwhile (FR-SCREEN-07).
            .onChange(of: scenePhase) { _, phase in
                receiver.setMirrorVisible(phase != .background)
            }
    }

    private var content: some View {
        NavigationStack {
            Group {
                if let session = receiver.activeSession {
                    ConnectedView(session: session)
                } else {
                    MacListView()
                }
            }
            .navigationTitle("SideCast")
        }
        .sheet(isPresented: Binding(
            get: { receiver.pairingSession != nil },
            set: { if !$0 { receiver.cancelPairing() } }
        )) {
            PairingEntryView()
        }
        .task {
            receiver.start()
        }
    }
}

private struct MacListView: View {
    @Environment(ReceiverController.self) private var receiver
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if receiver.node.localNetworkDenied {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Local network access is off", systemImage: "wifi.exclamationmark")
                            .font(.headline)
                        Text("SideCast needs local network access to find your Mac. Turn it on in Settings.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if let error = receiver.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                if receiver.senders.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for Macs running SideCast…")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(receiver.senders) { peer in
                    MacRow(peer: peer)
                }
            } header: {
                Text("Nearby Macs")
            } footer: {
                Text("Make sure SideCast is running on your Mac and both devices have Wi-Fi turned on. This device appears on the Mac as “\(receiver.identity.device.name)”.")
            }
            PremiumSection()
        }
    }
}

private struct MacRow: View {
    @Environment(ReceiverController.self) private var receiver
    let peer: DiscoveredPeer

    var body: some View {
        let status = receiver.status(for: peer.id)
        let paired = receiver.trustStore.peers.contains { $0.id == peer.id }
        let sameAccount = receiver.accountDirectory.containsDevice(id: peer.id)
            && !receiver.trustStore.revokedAccountDevices.contains(peer.id)
        Button {
            receiver.connect(peer)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: peer.device.platform.symbolName)
                    .font(.title3)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.device.name)
                        .foregroundStyle(.primary)
                    Group {
                        if sameAccount {
                            Text("Same Apple ID · Tap to connect")
                        } else if paired {
                            Text("Paired · Tap to connect")
                        } else {
                            Text("Tap to pair and connect")
                        }
                    }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if status == .connecting || status == .pairing {
                    ProgressView()
                }
            }
        }
        .disabled(status == .connecting || status == .pairing)
        .accessibilityIdentifier("mac-\(peer.device.name)")
    }
}

private struct ConnectedView: View {
    @Environment(ReceiverController.self) private var receiver
    let session: PeerSession
    @State private var showsPremium = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: receiver.currentStream == nil)
            VStack(spacing: 6) {
                Text("Connected to \(session.peer?.name ?? "")")
                    .font(.title2)
                    .multilineTextAlignment(.center)
                Group {
                    if let stream = receiver.currentStream {
                        Text(stream.codec == .opus ? "Low latency" : "High quality")
                    } else {
                        Text("Choose this device as an app's output on your Mac.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: Bindable(receiver).volume, in: 0...1)
                    .accessibilityLabel(Text("SideCast volume"))
                Image(systemName: "speaker.wave.3.fill")
            }
            .frame(maxWidth: 360)
            .foregroundStyle(.secondary)
            Button("Disconnect", role: .destructive) {
                receiver.disconnect()
            }
            .buttonStyle(.bordered)
            Text("Audio keeps playing when you lock the screen or switch apps.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button {
                showsPremium = true
            } label: {
                Label(
                    receiver.store.isUnlocked ? "Premium unlocked" : "SideCast Premium",
                    systemImage: "sparkles"
                )
            }
            .font(.callout)
        }
        .padding()
        .frame(maxWidth: 480)
        .sheet(isPresented: $showsPremium) {
            NavigationStack {
                List { PremiumSection() }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsPremium = false }
                        }
                    }
            }
        }
    }
}

private struct PairingEntryView: View {
    @Environment(ReceiverController.self) private var receiver
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Enter the code shown on \(receiver.pairingSession?.peer?.name ?? "your Mac")")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                TextField("000000", text: $code)
                    .font(.system(size: 36, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .accessibilityIdentifier("pairing-code")
                    .onChange(of: code) { _, newValue in
                        let digits = String(newValue.filter(\.isNumber).prefix(HandshakeCrypto.pairingCodeLength))
                        if digits != newValue { code = digits }
                    }
                if receiver.pairingSession?.state == .pairingVerifying {
                    ProgressView()
                }
                Button("Pair") {
                    receiver.submitPairingCode(code)
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.count != HandshakeCrypto.pairingCodeLength || receiver.pairingSession?.state != .pairingEnterCode)
                .accessibilityIdentifier("pair-button")
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { receiver.cancelPairing() }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}
#endif
