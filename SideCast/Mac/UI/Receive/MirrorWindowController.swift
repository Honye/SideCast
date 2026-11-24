//
//  MirrorWindowController.swift
//  SideCast
//
//  Receive mode: the mirrored screen of the other Mac in a window (can go full screen).
//  Closing the window stops mirroring; minimizing it pauses the stream (FR-SCREEN-07).
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
        window.setContentSize(NSSize(width: 960, height: 600))
        window.contentMinSize = NSSize(width: 320, height: 200)
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
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .top) {
            MirrorLayerView(renderer: receiver.mirrorRenderer)
            if receiver.mirror?.pictureSize == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if hovering {
                Button("Stop Mirroring", role: .destructive) {
                    receiver.stopMirroring()
                }
                .buttonStyle(.borderedProminent)
                .padding(12)
                .transition(.opacity)
            }
        }
        .frame(minWidth: 320, minHeight: 200)
        .onHover { inside in
            withAnimation { hovering = inside }
        }
    }
}
#endif
