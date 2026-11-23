//
//  MacAppDelegate.swift
//  SideCast
//

#if os(macOS)
import AppKit

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    let sender = SenderController()
    let preferences = AppPreferences()
    private(set) lazy var settingsWindow = SettingsWindowController(sender: sender, preferences: preferences)

    func applicationDidFinishLaunching(_ notification: Notification) {
        sender.onUpgradeNeeded = { reason in
            UpgradeAlert.present(reason)
        }
        sender.start()
        // First launch: explain permissions and how to start (FR-PERM-01).
        if !RuntimeEnvironment.isRunningTests, !UserDefaults.standard.bool(forKey: "onboarding.shown") {
            UserDefaults.standard.set(true, forKey: "onboarding.shown")
            settingsWindow.show(tab: .general)
        }
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
