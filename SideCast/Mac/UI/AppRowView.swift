//
//  AppRowView.swift
//  SideCast
//
//  One app in the menu bar list: output picker, volume slider, mute (FR-ROUTE-02, FR-VOL-01/02).
//

#if os(macOS)
import AppKit
import SwiftUI

struct AppRowView: View {
    @Environment(SenderController.self) private var sender
    let app: AudioApp

    var body: some View {
        let rule = sender.rule(for: app)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                AppIconView(bundleID: app.id)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .lineLimit(1)
                    if sender.offlineApps.contains(app.id) {
                        Label("Device offline", systemImage: "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 4)
                OutputPicker(app: app, selection: rule.target)
            }
            HStack(spacing: 6) {
                Button {
                    sender.setMuted(!rule.muted, for: app)
                } label: {
                    Image(systemName: rule.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(rule.muted ? Text("Unmute") : Text("Mute"))

                Slider(
                    value: Binding(
                        get: { rule.volume },
                        set: { sender.setVolume($0, for: app) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .disabled(rule.muted)

                LevelMeter(level: sender.levels[app.id] ?? 0)
                Text("\(Int((rule.volume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct OutputPicker: View {
    @Environment(SenderController.self) private var sender
    let app: AudioApp
    let selection: OutputTarget

    var body: some View {
        Picker(
            selection: Binding(get: { selection }, set: { sender.setTarget($0, for: app) })
        ) {
            Text("System Default").tag(OutputTarget.systemDefault)
            Divider()
            ForEach(sender.outputDevices) { device in
                Text(device.name).tag(OutputTarget.device(uid: device.id))
            }
            if !sender.connectedReceivers.isEmpty {
                Divider()
                ForEach(sender.connectedReceivers) { receiver in
                    Text(receiver.name).tag(OutputTarget.receiver(id: receiver.id))
                }
            }
            if !isAvailable(selection) {
                Divider()
                Text(sender.displayName(for: selection)).tag(selection)
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
    }

    private func isAvailable(_ target: OutputTarget) -> Bool {
        switch target {
        case .systemDefault: true
        case .device(let uid): sender.outputDevices.contains { $0.id == uid }
        case .receiver(let id): sender.connectedReceivers.contains { $0.id == id }
        }
    }
}

/// A small bar showing the app's current audio level.
private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.green)
                    .frame(width: proxy.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
        .frame(width: 28, height: 4)
        .accessibilityLabel(Text("Level"))
        .accessibilityValue(Text("\(Int(level * 100))%"))
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
