//
//  ReceiverRootView.swift
//  SideCast
//

#if !os(macOS)
import SwiftUI

struct ReceiverRootView: View {
    @Environment(ReceiverController.self) private var receiver

    var body: some View {
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

    var body: some View {
        List {
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
                    Button {
                        receiver.connect(peer)
                    } label: {
                        HStack {
                            Label(peer.device.name, systemImage: peer.device.platform.symbolName)
                            Spacer()
                            if receiver.status(for: peer.id) == .connecting {
                                ProgressView()
                            }
                        }
                    }
                    .accessibilityIdentifier("mac-\(peer.device.name)")
                }
            } header: {
                Text("Nearby Macs")
            } footer: {
                Text("Make sure SideCast is running on your Mac and both devices have Wi-Fi turned on.")
            }
        }
    }
}

private struct ConnectedView: View {
    @Environment(ReceiverController.self) private var receiver
    let session: PeerSession

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Connected to \(session.peer?.name ?? "")")
                .font(.title2)
            if let stream = receiver.currentStream {
                Text(stream.codec == .opus ? "Low latency" : "High quality")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: Bindable(receiver).volume, in: 0...1)
                    .accessibilityLabel(Text("Volume"))
                Image(systemName: "speaker.wave.3.fill")
            }
            .frame(maxWidth: 360)
            .foregroundStyle(.secondary)
            Button("Disconnect", role: .destructive) {
                receiver.disconnect()
            }
            .buttonStyle(.bordered)
        }
        .padding()
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
