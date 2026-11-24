//
//  MirrorWindowController.swift
//  SideCast
//
//  Receive mode: the mirrored screen of the other Mac in a window (can go full screen).
//  Closing the window stops mirroring; minimizing it pauses the stream (FR-SCREEN-07). With
//  mouse control on, the mouse in the window controls the other Mac (FR-TOUCH).
//

#if os(macOS)
import AppKit
import SwiftUI

final class MirrorWindowController: NSObject, NSWindowDelegate {
    private let receiver: ReceiverController
    private var window: NSWindow?

    init(receiver: ReceiverController) {
        self.receiver = receiver
    }

    /// Opens or closes the window to match the receiver's state.
    func update() {
        if let mirror = receiver.mirror {
            let window = self.window ?? makeWindow()
            self.window = window
            window.title = String(localized: "\(mirror.displayName) · \(mirror.macName)")
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else if let window {
            self.window = nil
            window.delegate = nil
            window.close()
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        receiver.stopMirroring()
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        receiver.setMirrorVisible(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        receiver.setMirrorVisible(true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingController(rootView: MirrorWindowContent().environment(receiver))
        // Keep the window's own size instead of shrinking it to the view's minimum.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        // Controls live in the title bar, never over the picture the mouse controls.
        let accessory = NSTitlebarAccessoryViewController()
        let controls = NSHostingView(rootView: MirrorWindowControls().environment(receiver))
        controls.frame.size = controls.fittingSize
        accessory.view = controls
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        // The title (display · Mac) stays in the Window menu and Mission Control; the title bar
        // has room for the controls only.
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 960, height: 600))
        window.contentMinSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setFrameAutosaveName("SideCastMirror")
        window.center()
        return window
    }
}

private struct MirrorWindowContent: View {
    @Environment(ReceiverController.self) private var receiver

    var body: some View {
        ZStack(alignment: .top) {
            MirrorLayerView(renderer: receiver.mirrorRenderer)
            if let pictureSize = receiver.mirror?.pictureSize {
                if receiver.touchControlActive {
                    MouseInputView(pictureSize: pictureSize) { kind, point, delta, unit in
                        receiver.sendPointer(kind, at: point, delta: delta, deltaUnit: unit)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if receiver.touchControlEnabled, receiver.mirror?.inputStatus == .needsPermission {
                Text("On the other Mac, allow SideCast in System Settings › Privacy & Security › Accessibility.")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 480, minHeight: 300)
    }
}

/// Title bar controls: mouse control on / off (FR-TOUCH-05) and stop mirroring (FR-SCREEN-09).
private struct MirrorWindowControls: View {
    @Environment(ReceiverController.self) private var receiver

    var body: some View {
        @Bindable var receiver = receiver
        HStack(spacing: 10) {
            if receiver.mirror?.inputStatus != .unsupported {
                Toggle("Mouse Control", isOn: $receiver.touchControlEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            Button("Stop Mirroring", role: .destructive) {
                receiver.stopMirroring()
            }
            .controlSize(.small)
        }
        .font(.callout)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 28)
    }
}
#endif
