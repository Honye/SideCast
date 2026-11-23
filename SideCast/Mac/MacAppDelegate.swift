//
//  MacAppDelegate.swift
//  SideCast
//

#if os(macOS)
import AppKit

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    let sender = SenderController()
    private(set) lazy var settingsWindow = SettingsWindowController(sender: sender)

    func applicationDidFinishLaunching(_ notification: Notification) {
        sender.start()
#if DEBUG
        DebugCommands.install(sender: sender, settings: settingsWindow)
#endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        sender.stop()
    }

    /// Opening SideCast again (Finder, Spotlight, Dock) shows the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }
}
#endif
