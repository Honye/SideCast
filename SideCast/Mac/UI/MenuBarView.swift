//
//  MenuBarView.swift
//  SideCast
//

#if os(macOS)
import SwiftUI

struct MenuBarView: View {
    @Environment(SenderController.self) private var sender

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SideCast")
                .font(.headline)
            Divider()
            SettingsLink {
                Text("Settings…")
            }
            Button("Quit SideCast") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 320)
    }
}
#endif
