//
//  OnboardingWindowController.swift
//  SideCast
//
//  The first-launch guide's window (FR-PERM-01). Shown on the first launch in send mode, and
//  from Settings › General.
//

#if os(macOS)
import AppKit
import SwiftUI

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shownKey = RuntimeEnvironment.profiled("onboarding.shown")

    private let sender: SenderController
    private var window: NSWindow?

    init(sender: SenderController) {
        self.sender = sender
    }

    func show() {
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        // Start from the first step each time.
        window?.close()
        let window = makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        DockIcon.hideIfNoWindows(closing: notification.object as? NSWindow)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Welcome to SideCast")
        window.titlebarAppearsTransparent = true
        let view = OnboardingView(close: { [weak window] in window?.close() }).environment(sender)
        window.contentViewController = NSHostingController(rootView: view)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}

/// SideCast shows a Dock icon only while one of its windows is open (PRD 6.8).
enum DockIcon {
    static func hideIfNoWindows(closing: NSWindow?) {
        let othersOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain }
        if !othersOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// Opens the first-launch guide again (Settings › General).
struct ShowOnboardingAction: Equatable {
    let run: () -> Void

    func callAsFunction() { run() }

    // There is only ever one, so views never need to update for a new one.
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var showOnboarding: ShowOnboardingAction?
}
#endif
