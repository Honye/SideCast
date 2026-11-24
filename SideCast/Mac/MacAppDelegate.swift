//
//  MacAppDelegate.swift
//  SideCast
//
//  The Mac app runs in one of two modes, chosen at launch (FR-RECV-07): as a sender (the
//  default) or as a receiver playing another Mac's audio.
//

#if os(macOS)
import AppKit
import SwiftUI

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    let mode = MacAppMode.stored
    let preferences = AppPreferences()
    /// Set in sender mode.
    let sender: SenderController?
    /// Set in receive mode.
    let receiver: ReceiverController?
    private(set) lazy var settingsWindow = makeSettingsWindow()

    override init() {
        sender = mode == .sender ? SenderController() : nil
        receiver = mode == .receiver ? ReceiverController() : nil
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let sender {
            sender.onUpgradeNeeded = { reason in
                UpgradeAlert.present(reason)
            }
            sender.start()
        }
        receiver?.start()
        // First launch: explain permissions and how to start (FR-PERM-01).
        if mode == .sender, !RuntimeEnvironment.isRunningTests, !UserDefaults.standard.bool(forKey: RuntimeEnvironment.profiled("onboarding.shown")) {
            UserDefaults.standard.set(true, forKey: RuntimeEnvironment.profiled("onboarding.shown"))
            settingsWindow.show(tab: .general)
        }
#if DEBUG
        if let sender {
            DebugCommands.install(sender: sender, settings: settingsWindow)
        }
        if let receiver {
            DebugCommands.install(receiver: receiver, settings: settingsWindow)
        }
#endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        sender?.stop()
        receiver?.stop()
    }

    /// Opening SideCast again (Finder, Spotlight, Dock) shows the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    private func makeSettingsWindow() -> SettingsWindowController {
        if let sender {
            SettingsWindowController(rootView: SettingsView().environment(sender).environment(preferences))
        } else {
            SettingsWindowController(rootView: ReceiverSettingsView().environment(receiver!).environment(preferences))
        }
    }
}
#endif
