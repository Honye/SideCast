//
//  SenderController+Premium.swift
//  SideCast
//
//  Business model (PRD 4, v0.4):
//  - The Mac app is free: per-app routing, volume and advanced mode on this Mac cost nothing.
//  - Each receiver (iPad / iPhone / Vision Pro) buys SideCast Premium on its own (App Store).
//  - A receiver without Premium only gets the "all audio" route (apps without their own
//    setting) and only one such receiver can be connected at a time.
//  - A receiver with Premium can receive single apps and doesn't count toward that limit.
//

#if os(macOS)
import CoreAudio
import Foundation

enum UpgradeReason {
    /// Sending a single app to a receiver without Premium.
    case singleAppToReceiver(name: String)
    /// A second receiver without Premium.
    case anotherUnpaidDevice
    /// Mirroring to several receivers at once while one of them has no Premium (FR-SCREEN-05).
    case mirrorToSeveral
}

enum PremiumTiming {
    /// How long a newly connected receiver has to report its premium status.
    static let statusGracePeriod: TimeInterval = 2
}

/// The limit of one connected receiver without Premium (FR-CONN-09), as a pure function.
enum DeviceLimitPolicy {
    struct Connection {
        let id: UUID
        /// nil while the receiver hasn't reported its status yet.
        let hasPremium: Bool?
        let readySince: Date
    }

    /// Receivers to disconnect, given connections in the order they connected.
    static func connectionsToClose(_ connections: [Connection], now: Date) -> [UUID] {
        var keptUnpaid = false
        var close: [UUID] = []
        for connection in connections {
            switch connection.hasPremium {
            case true?:
                continue
            case nil where now.timeIntervalSince(connection.readySince) < PremiumTiming.statusGracePeriod:
                continue // still waiting for its status
            default:
                if keptUnpaid {
                    close.append(connection.id)
                } else {
                    keptUnpaid = true
                }
            }
        }
        return close
    }
}

extension SenderController {
    func isPremium(receiver id: UUID) -> Bool {
        receiverPremium[id] == true
    }

    static func loadAllAudioTarget() -> OutputTarget {
        guard let data = UserDefaults.standard.data(forKey: RuntimeEnvironment.profiled("routing.freeTarget")),
              let target = try? JSONDecoder().decode(OutputTarget.self, from: data) else { return .systemDefault }
        return target
    }

    static let allAudioRouteKey = "__all__"

    /// Captures every process except SideCast's own and the ones that already have a route.
    func allAudioRouteUnit(connected: Set<UUID>, excluding routed: [AudioObjectID], offline: inout Set<String>) -> RouteUnit? {
        let key = Self.allAudioRouteKey
        let target: RouteTarget
        switch allAudioTarget {
        case .systemDefault:
            return nil
        case .device(let uid):
            if outputDevices.contains(where: { $0.id == uid }) {
                target = .device(uid)
            } else {
                target = .discard
                offline.insert(key)
            }
        case .receiver(let id):
            if connected.contains(id) {
                target = .receiver(id)
            } else {
                target = .discard
                offline.insert(key)
            }
        }
        return RouteUnit(
            key: key,
            name: "All audio",
            processes: Array(Set(ownProcessObjects + routed)).sorted(),
            target: target,
            gain: 1,
            capturesAllExcept: true
        )
    }

    /// Re-evaluates everything that depends on receivers' Premium status.
    func premiumChanged() {
        enforceDeviceLimit()
        enforceMirrorPolicy()
        refreshRoutes()
    }

    func enforceDeviceLimit() {
        let ready = sessions.filter { $0.state == .ready && $0.peer != nil }
        let connections = ready.compactMap { session -> DeviceLimitPolicy.Connection? in
            guard let id = session.peer?.id else { return nil }
            return DeviceLimitPolicy.Connection(
                id: id,
                hasPremium: premiumStatusReceived.contains(id) ? isPremium(receiver: id) : nil,
                readySince: readySince[id] ?? .distantPast
            )
        }
        let close = DeviceLimitPolicy.connectionsToClose(connections, now: Date())
        guard !close.isEmpty else { return }
        for session in ready where close.contains(session.peer?.id ?? UUID()) {
            if let id = session.peer?.id { markFreeLimit(id) }
            session.close(reason: GoodbyeReason.freeDeviceLimit)
        }
        onUpgradeNeeded?(.anotherUnpaidDevice)
    }
}
#endif
