//
//  SettingsView.swift
//  SideCast
//
//  The settings window (PRD 6.8): Apps, Devices, General.
//

#if os(macOS)
import SwiftUI

enum SettingsTab: String {
    case apps, devices, general
}

struct SettingsView: View {
    @AppStorage("settings.tab") private var tab: SettingsTab = .apps

    var body: some View {
        TabView(selection: $tab) {
            Tab("Apps", systemImage: "app.badge", value: .apps) {
                AppsSettingsView()
            }
            Tab("Devices", systemImage: "ipad.and.iphone", value: .devices) {
                DevicesSettingsView()
            }
            Tab("General", systemImage: "gearshape", value: .general) {
                GeneralSettingsView()
            }
        }
        .frame(minWidth: 600, minHeight: 460)
    }
}

// MARK: - Apps

private struct AppsSettingsView: View {
    @Environment(SenderController.self) private var sender

    var body: some View {
        Form {
            if sender.hasWarnings {
                WarningsView()
            }
                Section("Other sound") {
                    AllAudioRow()
                }
                Section {
                    if sender.visibleApps.isEmpty {
                        Text("Apps that play sound appear here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sender.visibleApps) { app in
                        AppRowView(app: app)
                    }
                } header: {
                    Text("Apps")
                } footer: {
                    Text("Apps you don't change play through the Mac as usual. Your choices are remembered for each app.")
                }

            let dormant = sender.dormantRules
            if !dormant.isEmpty {
                Section("Saved settings for apps that aren't running") {
                    ForEach(dormant, id: \.key) { entry in
                        HStack {
                            if !entry.key.contains("#") {
                                AppIconView(bundleID: entry.key)
                            }
                            VStack(alignment: .leading) {
                                Text(entry.rule.appName ?? entry.key)
                                Text(summary(of: entry.rule))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Forget") {
                                sender.resetRule(forKey: entry.key)
                            }
                        }
                    }
                }
            }
#if DEBUG
            Section("Debug trace") {
                Text(sender.debugLines.suffix(12).joined(separator: "\n"))
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
            }
#endif
        }
        .formStyle(.grouped)
    }

    private func summary(of rule: AppRule) -> String {
        let target = sender.displayName(for: rule.target)
        if rule.muted {
            return String(localized: "\(target) · Muted")
        }
        return String(localized: "\(target) · \(Int((rule.volume * 100).rounded()))%")
    }
}

// MARK: - Devices

private struct DevicesSettingsView: View {
    @Environment(SenderController.self) private var sender

    var body: some View {
        Form {
            if sender.hasWarnings {
                WarningsView()
            }
            Section {
                if sender.receiverRows.isEmpty {
                    Text("Open SideCast on your iPad, iPhone or Vision Pro, or turn on receive mode on another Mac. It appears here when it's on the same Wi-Fi network or nearby.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sender.receiverRows, id: \.device.id) { row in
                    ReceiverRow(device: row.device, peer: row.peer)
                }
            } header: {
                Text("Nearby devices")
            } footer: {
                Text("Low latency suits video, calls and games. High quality sends lossless audio with a little more delay.")
            }

            Section {
                if sender.trustStore.peers.isEmpty {
                    Text("No paired devices.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sender.trustStore.peers) { peer in
                    HStack {
                        Label(peer.device.name, systemImage: peer.device.platform.symbolName)
                        Spacer()
                        Text("Paired \(peer.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) {
                            sender.forget(peer.id)
                        }
                    }
                }
            } header: {
                Text("Paired devices")
            } footer: {
                Text("A removed device has to enter a new pairing code the next time it connects.")
            }

            Section {
                if sender.accountDirectory.devices.isEmpty {
                    Text(sender.accountDirectory.isAccountAvailable
                         ? "No other devices on your iCloud account have opened SideCast yet."
                         : "iCloud isn't signed in on this Mac.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sender.accountDirectory.devices) { entry in
                    let revoked = sender.trustStore.revokedAccountDevices.contains(entry.id)
                    HStack {
                        Label(entry.device.name, systemImage: entry.device.platform.symbolName)
                        Spacer()
                        Text(revoked ? "Needs a pairing code" : "Trusted automatically")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if revoked {
                            Button("Allow") { sender.trustStore.allowAccountDevice(id: entry.id) }
                        } else {
                            Button("Remove", role: .destructive) { sender.forget(entry.id) }
                        }
                    }
                }
            } header: {
                Text("Your devices on iCloud")
            } footer: {
                Text("Devices signed in to the same Apple ID connect without a pairing code. SideCast stores only each device's name and public key in your iCloud.")
            }

            Section("This Mac") {
                LabeledContent("Name", value: sender.identity.device.name)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @Environment(SenderController.self) private var sender

    var body: some View {
        @Bindable var sender = sender
        Form {
            PremiumInfoSection()

            StartupSection()
            LanguageSection()
            ModeSection(mode: .sender)

            Section {
                Toggle("Advanced mode", isOn: $sender.advancedMode)
            } footer: {
                Text("Lets you route and set the volume of each kind of process inside an app separately, for example a browser's helper processes.")
            }

            Section {
                PermissionRow(
                    title: Text("System audio recording"),
                    detail: Text("Needed to take an app's sound and play it on another device or at another volume. SideCast never records or saves audio."),
                    url: SystemSettingsLink.audioCapture
                )
                PermissionRow(
                    title: Text("Local network"),
                    detail: sender.node.localNetworkDenied
                        ? Text("Off. SideCast can't find your devices.")
                        : Text("Needed to find and connect to your devices."),
                    url: SystemSettingsLink.localNetwork
                )
            } header: {
                Text("Permissions")
            } footer: {
                Text("macOS asks for these the first time SideCast needs them. You can change them in System Settings › Privacy & Security.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let title: Text
    let detail: Text
    let url: URL

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                title
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings") { SystemSettingsLink.open(url) }
                .controlSize(.small)
        }
    }
}

// MARK: - Shared by both modes

/// Launch at login (Q14).
struct StartupSection: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        Section("Startup") {
            Toggle("Open SideCast when you log in", isOn: Binding(
                get: { preferences.launchAtLogin },
                set: { preferences.setLaunchAtLogin($0) }
            ))
            if preferences.launchAtLoginNeedsApproval {
                HStack {
                    Text("Allow SideCast in Login Items to finish turning this on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items") { SystemSettingsLink.open(SystemSettingsLink.loginItems) }
                        .controlSize(.small)
                }
            }
            if let error = preferences.launchAtLoginError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { preferences.refreshLaunchAtLogin() }
    }
}

/// Interface language (7.5).
struct LanguageSection: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Section("Language") {
            Picker("Language", selection: $preferences.language) {
                Text("Same as System").tag(AppLanguage.system)
                Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                Text(verbatim: "English").tag(AppLanguage.english)
            }
            if preferences.needsRelaunchForLanguage {
                HStack {
                    Text("Restart SideCast to use the new language.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Restart Now") { preferences.relaunch() }
                        .controlSize(.small)
                }
            }
        }
    }
}

/// Switches this Mac between sending and receiving (FR-RECV-07). Relaunches SideCast.
struct ModeSection: View {
    @Environment(AppPreferences.self) private var preferences
    let mode: MacAppMode
    @State private var confirming = false

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    switch mode {
                    case .sender:
                        Text("This Mac sends its audio")
                    case .receiver:
                        Text("This Mac plays audio from another Mac")
                    }
                }
                Spacer()
                Button {
                    confirming = true
                } label: {
                    switch mode {
                    case .sender: Text("Use as Receiver…")
                    case .receiver: Text("Use to Send Audio…")
                    }
                }
            }
        } header: {
            Text("Receive mode")
        } footer: {
            Text("In receive mode, another Mac can choose this Mac as an output, like an iPad. This Mac's own apps then play as usual, and SideCast restarts to switch.")
        }
        .confirmationDialog(confirmationTitle, isPresented: $confirming) {
            Button(mode == .sender ? "Switch to Receive Mode" : "Switch to Send Mode") {
                preferences.switchMode(to: mode == .sender ? .receiver : .sender)
            }
        } message: {
            if mode == .sender {
                Text("Connected devices are disconnected and every app plays through this Mac as usual until you switch back. Your settings are kept.")
            } else {
                Text("SideCast stops receiving and starts sending this Mac's audio again.")
            }
        }
    }

    private var confirmationTitle: Text {
        mode == .sender ? Text("Use this Mac as a receiver?") : Text("Use this Mac to send audio?")
    }
}
#endif
