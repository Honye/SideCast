//
//  SideCastApp.swift
//  SideCast
//

import SwiftUI

@main
struct SideCastApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appDelegate.sender)
        } label: {
            Image(systemName: "hifispeaker.2.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appDelegate.sender)
        }
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
