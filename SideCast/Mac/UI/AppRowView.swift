//
//  AppRowView.swift
//  SideCast
//
//  App rows shared by the menu bar and the settings window: output picker, volume slider,
//  mute (FR-ROUTE-02, FR-VOL-01/02), and in advanced mode per-process overrides (FR-ROUTE-10).
//

#if os(macOS)
import AppKit
import SwiftUI

struct AppRowView: View {
    @Environment(SenderController.self) private var sender
    let app: AudioApp
    @State private var showsProcesses = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RuleControls(
                title: app.name,
                iconBundleID: app.id,
                ruleKey: app.id,
                rule: sender.rule(forKey: app.id),
                isOverridden: sender.ruleStore.rules[app.id] != nil,
                choice: .target(sender.rule(forKey: app.id).target),
                allowsInherit: false,
                setTarget: { sender.setTarget($0, for: app) },
                setVolume: { sender.setVolume($0, for: app) },
                setMuted: { sender.setMuted($0, for: app) },
                reset: { sender.resetRule(for: app.id) }
            )
            let groups = app.processGroups
            if sender.advancedMode && groups.count > 1 {
                Button {
                    withAnimation(.snappy) { showsProcesses.toggle() }
                } label: {
                    Label {
                        Text("\(groups.count) processes")
                    } icon: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(showsProcesses ? 90 : 0))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .padding(.leading, 28)
                .accessibilityValue(showsProcesses ? Text("Expanded") : Text("Collapsed"))
                if showsProcesses {
                    ForEach(groups) { group in
                        ProcessGroupRow(app: app, group: group)
                            .padding(.leading, 28)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ProcessGroupRow: View {
    @Environment(SenderController.self) private var sender
    let app: AudioApp
    let group: ProcessGroup

    var body: some View {
        let rule = sender.effectiveRule(for: group)
        let overridden = sender.hasOverride(group)
        let name = "\(app.name) · \(group.displayName)"
        RuleControls(
            title: group.displayName,
            iconBundleID: nil,
            ruleKey: group.id,
            rule: rule,
            isOverridden: overridden,
            choice: overridden ? .target(rule.target) : .inherit,
            allowsInherit: true,
            setTarget: { target in sender.override(group, name: name) { $0.target = target } },
            setVolume: { volume in sender.override(group, name: name) { $0.volume = volume } },
            setMuted: { muted in sender.override(group, name: name) { $0.muted = muted } },
            reset: { sender.resetRule(forKey: group.id) }
        )
        .opacity(group.isPlaying || overridden ? 1 : 0.6)
    }
}

enum OutputChoice: Hashable {
    /// Per-process row: follow the app's rule.
    case inherit
    case target(OutputTarget)
}

/// Picker + volume + mute for one rule key.
struct RuleControls: View {
    @Environment(SenderController.self) private var sender
    let title: String
    let iconBundleID: String?
    let ruleKey: String
    let rule: AppRule
    let isOverridden: Bool
    let choice: OutputChoice
    let allowsInherit: Bool
    let setTarget: (OutputTarget) -> Void
    let setVolume: (Double) -> Void
    let setMuted: (Bool) -> Void
    let reset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let iconBundleID {
                    AppIconView(bundleID: iconBundleID)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if sender.premiumRequired.contains(ruleKey) {
                        Label("Needs Premium on the device", systemImage: "lock.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else if sender.offlineApps.contains(ruleKey) {
                        Label("Device offline", systemImage: "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 4)
                if isOverridden {
                    Button(action: reset) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help(allowsInherit ? Text("Follow the app's setting") : Text("Reset to system default"))
                }
                OutputPicker(choice: choice, allowsInherit: allowsInherit) { newChoice in
                    switch newChoice {
                    case .inherit:
                        reset()
                    case .target(.receiver(let id)) where !sender.isPremium(receiver: id):
                        // Single apps can only go to receivers with Premium (FR-PAY-01).
                        let name = sender.displayName(for: .receiver(id: id))
                        sender.onUpgradeNeeded?(.singleAppToReceiver(name: name))
                    case .target(let target):
                        setTarget(target)
                    }
                }
            }
            HStack(spacing: 6) {
                Button {
                    setMuted(!rule.muted)
                } label: {
                    Image(systemName: rule.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(rule.muted ? Text("Unmute") : Text("Mute"))
                .accessibilityLabel(rule.muted ? Text("Unmute") : Text("Mute"))

                Slider(value: Binding(get: { rule.volume }, set: setVolume), in: 0...1)
                    .controlSize(.small)
                    .disabled(rule.muted)
                    .accessibilityLabel(Text("Volume"))

                LevelMeter(level: sender.levels[ruleKey] ?? 0)
                Text(rule.volume, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }
}

private struct OutputPicker: View {
    @Environment(SenderController.self) private var sender
    let choice: OutputChoice
    let allowsInherit: Bool
    let onChange: (OutputChoice) -> Void

    var body: some View {
        Picker(selection: Binding(get: { choice }, set: onChange)) {
            if allowsInherit {
                Text("Same as app").tag(OutputChoice.inherit)
                Divider()
            }
            Text("System Default").tag(OutputChoice.target(.systemDefault))
            Section("This Mac") {
                ForEach(sender.outputDevices) { device in
                    Text(device.name).tag(OutputChoice.target(.device(uid: device.id)))
                }
            }
            if !sender.connectedReceivers.isEmpty {
                Section("SideCast devices") {
                    ForEach(sender.connectedReceivers) { receiver in
                        if sender.isPremium(receiver: receiver.id) {
                            Text(receiver.name).tag(OutputChoice.target(.receiver(id: receiver.id)))
                        } else {
                            Text("\(receiver.name) (needs Premium)").tag(OutputChoice.target(.receiver(id: receiver.id)))
                        }
                    }
                }
            }
            if case let .target(target) = choice, !isAvailable(target) {
                Divider()
                Text("\(sender.displayName(for: target)) (offline)").tag(choice)
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .accessibilityLabel(Text("Output"))
    }

    private func isAvailable(_ target: OutputTarget) -> Bool {
        switch target {
        case .systemDefault: true
        case .device(let uid): sender.outputDevices.contains { $0.id == uid }
        case .receiver(let id): sender.connectedReceivers.contains { $0.id == id }
        }
    }
}

/// A small bar showing the current audio level.
private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.green)
                    .frame(width: proxy.size.width * CGFloat(min(max(level * 2, 0), 1)))
            }
        }
        .frame(width: 28, height: 4)
        .accessibilityHidden(true)
    }
}

struct AppIconView: View {
    let bundleID: String

    var body: some View {
        Image(nsImage: AppIconCache.icon(for: bundleID))
            .resizable()
            .frame(width: 20, height: 20)
    }
}

enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let cached = cache[bundleID] { return cached }
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        cache[bundleID] = image
        return image
    }
}
#endif
