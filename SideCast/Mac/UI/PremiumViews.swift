//
//  PremiumViews.swift
//  SideCast
//
//  "All audio" output picker, upgrade prompts and the Premium explanation (PRD 4, v0.4).
//

#if os(macOS)
import AppKit
import SwiftUI

/// Where apps without their own setting play (FR-ROUTE-03). This is the only route a receiver
/// without Premium can take.
struct AllAudioRow: View {
    @Environment(SenderController.self) private var sender

    var body: some View {
        @Bindable var sender = sender
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "speaker.wave.2.circle")
                    .frame(width: 20)
                Text("Other sound")
                Spacer()
                Picker(selection: $sender.allAudioTarget) {
                    Text("This Mac (no change)").tag(OutputTarget.systemDefault)
                    Section("This Mac") {
                        ForEach(sender.outputDevices) { device in
                            Text(device.name).tag(OutputTarget.device(uid: device.id))
                        }
                    }
                    if !sender.connectedReceivers.isEmpty {
                        Section("SideCast devices") {
                            ForEach(sender.connectedReceivers) { receiver in
                                Text(receiver.name).tag(OutputTarget.receiver(id: receiver.id))
                            }
                        }
                    }
                    if !isAvailable(sender.allAudioTarget) {
                        Divider()
                        Text("\(sender.displayName(for: sender.allAudioTarget)) (offline)").tag(sender.allAudioTarget)
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .accessibilityLabel(Text("Output for other sound"))
            }
            if sender.offlineApps.contains(SenderController.allAudioRouteKey) {
                Label("Device offline", systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text("Sound from apps you haven't set separately.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func isAvailable(_ target: OutputTarget) -> Bool {
        switch target {
        case .systemDefault: true
        case .device(let uid): sender.outputDevices.contains { $0.id == uid }
        case .receiver(let id): sender.connectedReceivers.contains { $0.id == id }
        }
    }
}

/// Settings › General › SideCast Premium: explains the model and shows connected devices.
struct PremiumInfoSection: View {
    @Environment(SenderController.self) private var sender

    var body: some View {
        Section {
            if sender.connectedReceivers.isEmpty {
                Text("No devices connected.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sender.connectedReceivers) { receiver in
                LabeledContent {
                    if sender.isPremium(receiver: receiver.id) {
                        Label("Premium", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Free")
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label(receiver.name, systemImage: receiver.platform.symbolName)
                }
            }
        } header: {
            Text("SideCast Premium")
        } footer: {
            Text("SideCast on the Mac is free, including per-app output and volume on this Mac. SideCast Premium is a one-time purchase in SideCast on each iPad, iPhone or Vision Pro. A device with Premium can receive single apps and can be connected alongside other devices; a device without it receives the other sound, one device at a time.")
        }
    }
}

enum UpgradeAlert {
    @MainActor
    static func present(_ reason: UpgradeReason) {
        let alert = NSAlert()
        alert.messageText = String(localized: "This needs SideCast Premium on the device")
        switch reason {
        case .singleAppToReceiver(let name):
            alert.informativeText = String(localized: "To send a single app to \(name), buy SideCast Premium in SideCast on \(name). Until then \(name) can play the other sound.")
        case .anotherUnpaidDevice:
            alert.informativeText = String(localized: "Only one device without SideCast Premium can be connected at a time. Buy Premium in SideCast on the device to connect it alongside others.")
        case .mirrorToSeveral:
            alert.informativeText = String(localized: "To mirror to several devices at once, each of them needs SideCast Premium. Stop mirroring to the other device first, or buy Premium in SideCast on the devices.")
        }
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate()
        alert.runModal()
    }
}
#endif
