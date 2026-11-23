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
            MenuBarView(openSettings: { appDelegate.settingsWindow.show() })
                .environment(appDelegate.sender)
        } label: {
            Image(systemName: "hifispeaker.2.fill")
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
