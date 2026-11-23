//
//  RuleStore.swift
//  SideCast
//
//  Per-app routing and volume, remembered across launches (FR-ROUTE-08, FR-VOL-03).
//

#if os(macOS)
import Foundation
import Observation

/// Where the user wants an app's audio to go.
enum OutputTarget: Hashable, Codable {
    /// Follow macOS's default output device (FR-ROUTE-06).
    case systemDefault
    /// A local output device, by Core Audio UID.
    case device(uid: String)
    /// A SideCast receiver, by device ID.
    case receiver(id: UUID)
}

struct AppRule: Codable, Hashable {
    var target: OutputTarget = .systemDefault
    /// 0…1, relative to the app's own volume (FR-VOL-01).
    var volume: Double = 1
    var muted = false
    /// Last known display name, for listing apps that are not running.
    var appName: String?

    /// True when SideCast does not need to touch the app's audio at all.
    var isPassthrough: Bool {
        target == .systemDefault && volume >= 0.999 && !muted
    }
}

@Observable
final class RuleStore {
    private(set) var rules: [String: AppRule] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey = "routing.rules"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode([String: AppRule].self, from: data) {
            rules = stored
        }
    }

    func rule(for appID: String) -> AppRule {
        rules[appID] ?? AppRule()
    }

    /// - Parameter keepPassthrough: keep the rule even if it equals the defaults (used for
    ///   per-process overrides, where "default" still differs from inheriting the app's rule).
    func update(_ appID: String, name: String?, keepPassthrough: Bool = false, _ change: (inout AppRule) -> Void) {
        var rule = rule(for: appID)
        change(&rule)
        if let name { rule.appName = name }
        if rule.isPassthrough && !keepPassthrough {
            rules.removeValue(forKey: appID)
        } else {
            rules[appID] = rule
        }
        save()
    }

    func reset(_ appID: String) {
        rules.removeValue(forKey: appID)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
#endif
