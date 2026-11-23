//
//  SettingsWindowController.swift
//  SideCast
//
//  The settings window. SideCast has no Dock icon; it shows one only while this window is open
//  (PRD 6.8).
//

#if os(macOS)
import AppKit
import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let sender: SenderController
    private let preferences: AppPreferences

    init(sender: SenderController, preferences: AppPreferences) {
        self.sender = sender
        self.preferences = preferences
    }

    func show(tab: SettingsTab? = nil) {
        if let tab {
            UserDefaults.standard.set(tab.rawValue, forKey: "settings.tab")
        }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "SideCast Settings")
        window.contentViewController = NSHostingController(
            rootView: SettingsView().environment(sender).environment(preferences)
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("SideCastSettings")
        window.center()
        return window
    }
}
#endif
