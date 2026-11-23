//
//  PremiumViews.swift
//  SideCast
//
//  Free version output picker, upgrade prompts and the Premium (license) settings section.
//

#if os(macOS)
import AppKit
import SwiftUI

/// Free version: one output for all of the Mac's audio (FR-ROUTE-03).
struct FreeOutputRow: View {
    @Environment(SenderController.self) private var sender

    var body: some View {
        @Bindable var sender = sender
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "macbook")
                    .frame(width: 20)
                Text("Mac audio")
                Spacer()
                Picker(selection: $sender.freeTarget) {
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
                    if !isAvailable(sender.freeTarget) {
                        Divider()
                        Text("\(sender.displayName(for: sender.freeTarget)) (offline)").tag(sender.freeTarget)
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .accessibilityLabel(Text("Output for all Mac audio"))
            }
            if sender.offlineApps.contains(SenderController.freeRouteKey) {
                Label("Device offline", systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text("Sends all of the Mac's sound to one place.")
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

/// Explains a premium feature with a button to the Premium settings (FR-PAY-01).
struct UpgradeBanner: View {
    let openPremium: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Per-app output and volume are part of SideCast Premium.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Learn about Premium…", action: openPremium)
                    .controlSize(.small)
            }
        }
    }
}

/// Settings › General › SideCast Premium.
struct PremiumSettingsSection: View {
    @Environment(SenderController.self) private var sender
    @State private var key = ""

    var body: some View {
        let license = sender.license
        Section {
            switch sender.premiumSource {
            case .license:
                LabeledContent("Status") {
                    Label("Unlocked", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            case .receiver(let name):
                LabeledContent("Status") {
                    Text("Unlocked while connected to \(name)")
                        .foregroundStyle(.green)
                }
            case .none:
                LabeledContent("Status", value: String(localized: "Free version"))
            }

            if case let .licensed(suffix) = license.state {
                LabeledContent("License key") {
                    Text(verbatim: "••••-\(suffix)")
                        .font(.body.monospaced())
                }
                Button("Deactivate on This Mac") {
                    Task { await license.deactivate() }
                }
            } else {
                HStack {
                    TextField("License key", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .disableAutocorrection(true)
                    Button("Activate") {
                        Task { await license.activate(key: key) }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || license.state == .working)
                }
                if license.state == .working {
                    ProgressView().controlSize(.small)
                }
                if let url = license.checkoutURL {
                    Button("Buy SideCast Premium…") { NSWorkspace.shared.open(url) }
                }
            }
            if let error = license.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("SideCast Premium")
        } footer: {
            Text("Premium adds per-app output and volume, and lets you connect several devices at once. It's a one-time purchase. If an iPad or iPhone bought Premium in the App Store, it's unlocked while that device is connected.")
        }
    }
}

enum UpgradeAlert {
    @MainActor
    static func present(_ reason: UpgradeReason, openPremium: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = String(localized: "This needs SideCast Premium")
        switch reason {
        case .multipleDevices:
            alert.informativeText = String(localized: "The free version connects one device at a time. With Premium you can connect several devices and send different apps to each.")
        case .perAppControl:
            alert.informativeText = String(localized: "With Premium you can choose an output and volume for each app.")
        }
        alert.addButton(withTitle: String(localized: "Learn about Premium…"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            openPremium()
        }
    }
}
#endif
