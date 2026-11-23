//
//  SettingsView.swift
//  SideCast
//

#if os(macOS)
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Apps", systemImage: "app.badge") {
                AppsSettingsView()
            }
            Tab("Devices", systemImage: "ipad.and.iphone") {
                DevicesSettingsView()
            }
        }
        .frame(minWidth: 560, minHeight: 400)
    }
}

private struct AppsSettingsView: View {
    @Environment(SenderController.self) private var sender

    var body: some View {
        List {
            if let error = sender.audioError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            Section {
                ForEach(sender.visibleApps) { app in
                    AppRowView(app: app)
                }
                if sender.visibleApps.isEmpty {
                    Text("Apps that play sound appear here.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Playing or customized")
            }
#if DEBUG
            Section("Debug trace") {
                Text(sender.debugLines.suffix(12).joined(separator: "\n"))
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
            }
#endif
        }
    }
}

private struct DevicesSettingsView: View {
    @Environment(SenderController.self) private var sender

    var body: some View {
        List {
            Section("Paired devices") {
                if sender.trustStore.peers.isEmpty {
                    Text("No paired devices.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sender.trustStore.peers) { peer in
                    HStack {
                        Label(peer.device.name, systemImage: peer.device.platform.symbolName)
                        Spacer()
                        StatusText(status: sender.status(for: peer.id))
                        Button("Remove", role: .destructive) {
                            sender.forget(peer.id)
                        }
                    }
                }
            }
        }
    }
}
#endif
