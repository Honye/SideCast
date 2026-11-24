//
//  DebugCommands.swift
//  SideCast
//
//  Debug builds only. Lets a developer drive SideCast from Terminal for testing, e.g.:
//
//    osascript -l JavaScript -e 'ObjC.import("Foundation");
//      $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(
//        "com.imarkr.SideCast.debug", "{\"cmd\":\"route\",\"app\":\"com.apple.afplay\",\"device\":\"BuiltInSpeakerDevice\",\"volume\":0.5}", $(), true)'
//
//  Commands: route (app, device UID | "default" | "receiver:<uuid>" | "receiver:first", volume, muted), reset (app),
//  mode (receiver, lowLatency | highQuality), premium (receiver, unlocked: simulates a receiver's
//  purchase), all (device: like route, for the "other sound" output), settings.
//  In receive mode: connect (mac: part of the name), pair (code), disconnect, volume (value), settings,
//  menu (shows the menu bar popover's content in a window).
//  With SIDECAST_PROFILE set, the notification name ends in ".<profile>" so instances don't mix.
//

#if os(macOS) && DEBUG
import AppKit
import Foundation
import SwiftUI

enum DebugCommands {
    private static var menuPreview: NSWindow?

    static let name = Notification.Name(
        RuntimeEnvironment.profile.map { "com.imarkr.SideCast.debug.\($0)" } ?? "com.imarkr.SideCast.debug"
    )

    static func install(sender: SenderController, settings: SettingsWindowController) {
        observe { cmd, command in
            run(cmd, command, sender: sender, settings: settings)
        }
    }

    static func install(receiver: ReceiverController, settings: SettingsWindowController) {
        observe { cmd, command in
            DebugTrace.write("debug command \(command)")
            switch cmd {
            case "settings":
                settings.show()
            case "menu":
                // The menu bar popover's content in a window, for screenshots.
                let window = NSWindow(contentViewController: NSHostingController(
                    rootView: ReceiverMenuView(openSettings: { settings.show() }).environment(receiver)
                ))
                window.title = "Menu preview"
                window.isReleasedWhenClosed = false
                window.makeKeyAndOrderFront(nil)
                menuPreview = window
            case "connect":
                let name = command["mac"] as? String ?? ""
                if let peer = receiver.senders.first(where: { name.isEmpty || $0.device.name.contains(name) }) {
                    receiver.connect(peer)
                }
            case "pair":
                if let code = command["code"] as? String {
                    receiver.submitPairingCode(code)
                }
            case "disconnect":
                receiver.disconnect()
            case "volume":
                if let volume = command["value"] as? Double {
                    receiver.volume = volume
                }
            default:
                break
            }
        }
    }

    private static func observe(_ handler: @escaping @MainActor (String, [String: Any]) -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { notification in
            guard let json = notification.object as? String,
                  let data = json.data(using: .utf8),
                  let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cmd = command["cmd"] as? String else { return }
            MainActor.assumeIsolated {
                handler(cmd, command)
            }
        }
    }

    private static func run(_ cmd: String, _ command: [String: Any], sender: SenderController, settings: SettingsWindowController) {
        DebugTrace.write("debug command \(command)")
        switch cmd {
        case "settings":
            settings.show()
        case "route":
            guard let appID = command["app"] as? String else { return }
            let app = sender.apps.first { $0.id == appID } ?? AudioApp(id: appID, name: appID, processes: [])
            if let device = command["device"] as? String {
                let target: OutputTarget
                if device == "default" {
                    target = .systemDefault
                } else if device == "receiver:first", let id = sender.connectedReceivers.first?.id {
                    target = .receiver(id: id)
                } else if device.hasPrefix("receiver:"), let id = UUID(uuidString: String(device.dropFirst(9))) {
                    target = .receiver(id: id)
                } else {
                    target = .device(uid: device)
                }
                sender.setTarget(target, for: app)
            }
            if let volume = command["volume"] as? Double {
                sender.setVolume(volume, for: app)
            }
            if let muted = command["muted"] as? Bool {
                sender.setMuted(muted, for: app)
            }
        case "mode":
            if let receiver = (command["receiver"] as? String).flatMap(UUID.init(uuidString:)),
               let mode = (command["mode"] as? String).flatMap(AudioMode.init(rawValue:)) {
                sender.setAudioMode(mode, for: receiver)
            }
        case "premium":
            if let receiver = (command["receiver"] as? String).flatMap(UUID.init(uuidString:)) {
                sender.receiverPremium[receiver] = command["unlocked"] as? Bool ?? false
                sender.premiumStatusReceived.insert(receiver)
                sender.premiumChanged()
            }
        case "all", "free":
            if let device = command["device"] as? String {
                if device == "default" {
                    sender.allAudioTarget = .systemDefault
                } else if device.hasPrefix("receiver:"), let id = UUID(uuidString: String(device.dropFirst(9))) {
                    sender.allAudioTarget = .receiver(id: id)
                } else {
                    sender.allAudioTarget = .device(uid: device)
                }
            }
        case "reset":
            if let appID = command["app"] as? String {
                sender.resetRule(for: appID)
            }
        default:
            break
        }
    }
}
#endif
