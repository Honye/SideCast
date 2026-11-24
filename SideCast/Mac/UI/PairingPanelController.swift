//
//  PairingPanelController.swift
//  SideCast
//
//  Floating panel that shows the pairing code, so the user sees it even when the menu bar
//  popover is closed (for example when the iPad starts the connection).
//

#if os(macOS)
import AppKit
import SwiftUI

final class PairingPanelController {
    private var panel: NSPanel?
    private var shownCode: String?

    func show(code: String, deviceName: String, onCancel: @escaping () -> Void) {
        guard shownCode != code else { return }
        shownCode = code
#if DEBUG
        // Only for side-by-side test instances, so a script can type the code.
        if RuntimeEnvironment.profile != nil {
            DebugTrace.write("pairing code \(code)")
        }
#endif
        let view = PairingCodeView(code: code, deviceName: deviceName) { [weak self] in
            onCancel()
            self?.hide()
        }
        let panel = self.panel ?? makePanel()
        panel.contentViewController = NSHostingController(rootView: view)
        panel.center()
        panel.orderFrontRegardless()
        NSApp.activate()
        self.panel = panel
    }

    func hide() {
        shownCode = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "Pair Device")
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }
}

struct PairingCodeView: View {
    let code: String
    let deviceName: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Enter this code on \(deviceName)")
                .font(.headline)
            Text(code.map(String.init).joined(separator: " "))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
            Text("The code is valid for 2 minutes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Cancel", role: .cancel, action: onCancel)
        }
        .padding(24)
        .frame(width: 360)
    }
}
#endif
