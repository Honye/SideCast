//
//  SideCastApp.swift
//  SideCast
//

import SwiftUI

#if os(macOS)
/// Filled icon while a device is connected.
private struct MenuBarIcon: View {
    @Environment(SenderController.self) private var sender

    var body: some View {
        Image(systemName: sender.connectedReceivers.isEmpty ? "hifispeaker.2" : "hifispeaker.2.fill")
            .accessibilityLabel(Text("SideCast"))
    }
}
#endif

@main
struct SideCastApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(openSettings: { appDelegate.settingsWindow.show() })
                .environment(appDelegate.sender)
        } label: {
            MenuBarIcon()
                .environment(appDelegate.sender)
        }
        .menuBarExtraStyle(.window)
    }
#else
    @State private var receiver = ReceiverController()

    var body: some Scene {
        WindowGroup {
            ReceiverRootView()
                .environment(receiver)
        }
    }
#endif
}
