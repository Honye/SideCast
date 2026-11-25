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
    private lazy var onboardingWindow = sender.map { OnboardingWindowController(sender: $0) }
    private var mirrorWindow: MirrorWindowController?

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
        if let receiver {
            let mirrorWindow = MirrorWindowController(receiver: receiver)
            receiver.onMirrorChanged = { [weak mirrorWindow] in mirrorWindow?.update() }
            self.mirrorWindow = mirrorWindow
            receiver.start()
        }
        // First launch: the step-by-step guide (FR-PERM-01).
        if mode == .sender, !RuntimeEnvironment.isRunningTests, !UserDefaults.standard.bool(forKey: OnboardingWindowController.shownKey) {
            onboardingWindow?.show()
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
            SettingsWindowController(rootView: SettingsView()
                .environment(sender)
                .environment(preferences)
                .environment(\.showOnboarding, ShowOnboardingAction { [weak self] in self?.onboardingWindow?.show() }))
        } else {
            SettingsWindowController(rootView: ReceiverSettingsView().environment(receiver!).environment(preferences))
        }
    }
}
#endif
