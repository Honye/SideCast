//
//  SenderController+Premium.swift
//  SideCast
//
//  Free vs Premium on the Mac (PRD 4, FR-PAY-01~05, FR-CONN-09):
//  - Premium: per-app routing and volume, several receivers at once.
//  - Free: all of the Mac's audio to one output, one receiver at a time.
//  - Premium is on while this Mac has a license OR any connected receiver bought Premium;
//    it ends with that connection (FR-PAY-04).
//

#if os(macOS)
import Foundation

enum UpgradeReason {
    case perAppControl
    case multipleDevices
}

enum PremiumSource: Equatable {
    case none
    case license
    case receiver(name: String)
}

enum PremiumTiming {
    /// How long a newly connected receiver has to report its premium status.
    static let statusGracePeriod: TimeInterval = 2
}

extension SenderController {
    var isPremium: Bool {
        premiumSource != .none
    }

    var premiumSource: PremiumSource {
        if license.isLicensed { return .license }
        if let receiver = connectedReceivers.first(where: { receiverPremium[$0.id] == true }) {
            return .receiver(name: receiver.name)
        }
        return .none
    }

    static func loadFreeTarget() -> OutputTarget {
        guard let data = UserDefaults.standard.data(forKey: "routing.freeTarget"),
              let target = try? JSONDecoder().decode(OutputTarget.self, from: data) else { return .systemDefault }
        return target
    }

    /// The free version's single route: every process except SideCast itself.
    func freeRouteUnit(connected: Set<UUID>, offline: inout Set<String>) -> RouteUnit? {
        let key = Self.freeRouteKey
        let target: RouteTarget
        switch freeTarget {
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
            processes: ownProcessObjects,
            target: target,
            gain: 1,
            capturesAllExcept: true
        )
    }

    static let freeRouteKey = "__all__"

    /// Re-evaluates everything that depends on Premium.
    func premiumChanged() {
        let licensed = license.isLicensed
        if licensed != lastSentPremium {
            lastSentPremium = licensed
            for session in sessions where session.state == .ready {
                session.send(.premiumStatus(unlocked: licensed))
            }
        }
        enforceDeviceLimit()
        refreshRoutes()
    }

    /// Free version: keep the first connected receiver and disconnect the rest (FR-CONN-09).
    func enforceDeviceLimit() {
        guard !isPremium else { return }
        let ready = sessions.filter { $0.state == .ready && $0.peer != nil }
        guard ready.count > 1 else { return }
        let now = Date()
        var closedAny = false
        for session in ready.dropFirst() {
            guard let id = session.peer?.id else { continue }
            // Still waiting for this receiver to say whether it has Premium.
            if !premiumStatusReceived.contains(id),
               let since = readySince[id], now.timeIntervalSince(since) < PremiumTiming.statusGracePeriod {
                continue
            }
            markFreeLimit(id)
            session.close(reason: GoodbyeReason.freeDeviceLimit)
            closedAny = true
        }
        if closedAny {
            onUpgradeNeeded?(.multipleDevices)
        }
    }
}
#endif
