//
//  ReceiverSettingsView.swift
//  SideCast
//
//  Settings window in receive mode (FR-RECV-07): the mode switch, paired Macs, startup and
//  language.
//

#if os(macOS)
import SwiftUI

struct ReceiverSettingsView: View {
    @Environment(ReceiverController.self) private var receiver

    var body: some View {
        Form {
            ModeSection(mode: .receiver)

            Section {
                let macs = receiver.trustStore.peers.filter { $0.device.platform == .mac }
                if macs.isEmpty {
                    Text("No paired Macs.")
                        .foregroundStyle(.secondary)
                }
                ForEach(macs) { peer in
                    HStack {
                        Label(peer.device.name, systemImage: peer.device.platform.symbolName)
                        Spacer()
                        Text("Paired \(peer.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) {
                            receiver.forget(peer.id)
                        }
                    }
                }
            } header: {
                Text("Paired Macs")
            } footer: {
                Text("Macs on your Apple ID connect without a pairing code. A removed Mac needs a new pairing code the next time it connects.")
            }

            Section {
                LabeledContent("Name", value: receiver.identity.device.name)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local network")
                        Group {
                            if receiver.node.localNetworkDenied {
                                Text("Off. SideCast can't find your Mac.")
                            } else {
                                Text("Needed to find and connect to your Mac.")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Settings") { SystemSettingsLink.open(SystemSettingsLink.localNetwork) }
                        .controlSize(.small)
                }
            } header: {
                Text("This Mac")
            }

            StartupSection()
            LanguageSection()
#if DEBUG
            Section("Debug trace") {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(DebugTrace.recent().suffix(8).joined(separator: "\n"))
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
#endif
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 420)
    }
}
#endif
