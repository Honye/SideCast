//
//  RuntimeEnvironment.swift
//  SideCast
//

import Foundation

nonisolated enum RuntimeEnvironment {
    enum Distribution {
        /// Developer ID, from the website: everything, including the audio driver.
        case website
        /// Mac App Store (and the iOS / visionOS receivers): no driver, no non-public APIs.
        case appStore
    }

    /// How this build is distributed (PRD 3.2), from the SIDECAST_DISTRIBUTION build setting
    /// (the AppStore build configuration sets it to APP_STORE).
    static let distribution: Distribution = {
#if DISTRIBUTION_APP_STORE || !os(macOS)
        return .appStore
#else
        return .website
#endif
    }()

    /// True when the app is hosting unit tests. Networking and audio stay off then.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    /// Debug builds only: `SIDECAST_PROFILE=B` runs a second, independent SideCast on the same
    /// Mac (its own device identity, trusted devices and mode), so a sender and a receiver can be
    /// tested side by side.
    static let profile: String? = {
#if DEBUG
        let value = ProcessInfo.processInfo.environment["SIDECAST_PROFILE"] ?? ""
        return value.isEmpty ? nil : value
#else
        return nil
#endif
    }()

    /// Tests and debug profiles keep the same-Apple-ID device list in memory, so test devices
    /// never appear on the user's real devices.
    static var usesICloud: Bool { !isRunningTests && profile == nil }

    /// Debug builds only: `SIDECAST_MODE=receiver` starts the Mac app in that mode for this run.
    static let modeOverride: String? = {
#if DEBUG
        ProcessInfo.processInfo.environment["SIDECAST_MODE"]
#else
        nil
#endif
    }()

    /// `key`, namespaced by the debug profile when one is set.
    static func profiled(_ key: String) -> String {
        profile.map { "\(key).profile-\($0)" } ?? key
    }
}
