//
//  MenuBarView.swift
//  SideCast
//
//  The menu bar popover: devices and apps for quick changes (PRD 6.8).
//

#if os(macOS)
import SwiftUI

struct MenuBarView: View {
    @Environment(SenderController.self) private var sender
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SideCast")
                    .font(.headline)
                Spacer()
                if !sender.connectedReceivers.isEmpty {
                    Text("\(sender.connectedReceivers.count) connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            WarningsView()

            Section {
                if sender.receiverRows.isEmpty {
                    Text("Open SideCast on your iPad to see it here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(sender.receiverRows, id: \.device.id) { row in
                    ReceiverRow(device: row.device, peer: row.peer)
                }
            } header: {
                SectionHeader(title: Text("Devices"))
            }

            Divider()

            Section {
                if sender.visibleApps.isEmpty {
                    Text("Apps that play sound appear here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(sender.visibleApps) { app in
                            AppRowView(app: app)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                SectionHeader(title: Text("Apps"))
            }

            Divider()
            HStack {
                Button("Settings…", action: openSettings)
                Spacer()
                Button("Quit SideCast") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .frame(width: 380)
    }
}

private struct SectionHeader: View {
    let title: Text

    var body: some View {
        title
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
#endif
