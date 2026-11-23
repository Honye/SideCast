//
//  AppPreferences.swift
//  SideCast
//
//  General settings of the Mac app: launch at login and interface language (PRD Q14, 7.5).
//

#if os(macOS)
import AppKit
import Foundation
import Observation
import os
import ServiceManagement

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
}

@Observable
final class AppPreferences {
    private(set) var launchAtLogin = false
    private(set) var launchAtLoginNeedsApproval = false
    private(set) var launchAtLoginError: String?

    var language: AppLanguage {
        didSet { applyLanguage() }
    }

    /// The language in effect for this run; a change needs a relaunch.
    let languageAtLaunch: AppLanguage

    var needsRelaunchForLanguage: Bool { language != languageAtLaunch }

    @ObservationIgnored private let languageKey = "app.language"

    init() {
        let stored = UserDefaults.standard.string(forKey: languageKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
        language = stored
        languageAtLaunch = stored
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchAtLoginNeedsApproval = status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("Launch at login: \(error.localizedDescription, privacy: .public)")
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    /// Starts a new instance of SideCast and quits this one.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    private func applyLanguage() {
        let defaults = UserDefaults.standard
        defaults.set(language.rawValue, forKey: languageKey)
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
}

enum SystemSettingsLink {
    static let audioCapture = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
    static let localNetwork = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
    static let loginItems = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
#endif
