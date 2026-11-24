//
//  SideCastApp.swift
//  SideCast
//

import SwiftUI

#if os(macOS)
/// Filled icon while a device is connected.
private struct SenderMenuBarIcon: View {
    @Environment(SenderController.self) private var sender

    var body: some View {
        Image(systemName: sender.connectedReceivers.isEmpty ? "hifispeaker.2" : "hifispeaker.2.fill")
            .accessibilityLabel(Text("SideCast"))
    }
}

/// Receive mode: a single speaker, filled while a Mac is connected.
private struct ReceiverMenuBarIcon: View {
    @Environment(ReceiverController.self) private var receiver

    var body: some View {
        Image(systemName: receiver.activeSession == nil ? "hifispeaker" : "hifispeaker.fill")
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
            if let sender = appDelegate.sender {
                MenuBarView(openSettings: { appDelegate.settingsWindow.show() })
                    .environment(sender)
            } else if let receiver = appDelegate.receiver {
                ReceiverMenuView(openSettings: { appDelegate.settingsWindow.show() })
                    .environment(receiver)
            }
        } label: {
            if let sender = appDelegate.sender {
                SenderMenuBarIcon()
                    .environment(sender)
            } else if let receiver = appDelegate.receiver {
                ReceiverMenuBarIcon()
                    .environment(receiver)
            }
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
