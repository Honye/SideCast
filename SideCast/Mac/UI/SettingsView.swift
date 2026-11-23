//
//  SettingsView.swift
//  SideCast
//

#if os(macOS)
import SwiftUI

struct SettingsView: View {
    @Environment(SenderController.self) private var sender

    var body: some View {
        Text("Settings")
            .frame(width: 480, height: 320)
    }
}
#endif
