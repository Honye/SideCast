//
//  MacAppDelegate.swift
//  SideCast
//

#if os(macOS)
import AppKit

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    let sender = SenderController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        sender.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sender.stop()
    }
}
#endif
