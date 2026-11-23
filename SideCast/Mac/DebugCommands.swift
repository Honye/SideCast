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
//  Commands: route (app, device UID | "default" | "receiver:<uuid>", volume, muted), reset (app),
//  settings.
//

#if os(macOS) && DEBUG
import AppKit
import Foundation

enum DebugCommands {
    static let name = Notification.Name("com.imarkr.SideCast.debug")

    static func install(sender: SenderController, settings: SettingsWindowController) {
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { notification in
            guard let json = notification.object as? String,
                  let data = json.data(using: .utf8),
                  let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cmd = command["cmd"] as? String else { return }
            MainActor.assumeIsolated {
                run(cmd, command, sender: sender, settings: settings)
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
