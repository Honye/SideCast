//
//  LicenseManager.swift
//  SideCast
//
//  SideCast Premium for the website version of the Mac app (FR-PAY-03): a LemonSqueezy license
//  key, activated for this Mac and kept in the Keychain. Validated again at launch; if the
//  server can't be reached the last known state is kept so SideCast works offline.
//

#if os(macOS)
import Foundation
import Observation
import os

@Observable
final class LicenseManager {
    enum State: Equatable {
        case unlicensed
        case working
        case licensed(keySuffix: String)
    }

    private(set) var state: State = .unlicensed
    private(set) var lastError: String?

    var isLicensed: Bool {
#if DEBUG
        if debugUnlocked { return true }
#endif
        if case .licensed = state { return true }
        return false
    }

#if DEBUG
    /// Debug builds: lets tests and the debug command channel simulate a license.
    var debugUnlocked = false
#endif

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let client: LemonSqueezyClient
    @ObservationIgnored private let keychainAccount: String

    private struct Stored: Codable {
        var key: String
        var instanceID: String
        var validatedAt: Date
    }

    init(client: LemonSqueezyClient = LemonSqueezyClient(config: .production), keychainAccount: String = "license") {
        self.client = client
        self.keychainAccount = keychainAccount
        if let stored = loadStored() {
            state = .licensed(keySuffix: Self.suffix(of: stored.key))
        }
    }

    var checkoutURL: URL? { client.config.checkoutURL }

    func activate(key rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        lastError = nil
        let previous = state
        state = .working
        do {
            let instanceID = try await client.activate(key: key, instanceName: DeviceName.current)
            store(Stored(key: key, instanceID: instanceID, validatedAt: Date()))
            state = .licensed(keySuffix: Self.suffix(of: key))
        } catch {
            lastError = Self.message(for: error)
            state = previous == .working ? .unlicensed : previous
        }
        onChange?()
    }

    /// Frees the activation so the key can be used on another Mac.
    func deactivate() async {
        guard let stored = loadStored() else { return }
        lastError = nil
        state = .working
        do {
            try await client.deactivate(key: stored.key, instanceID: stored.instanceID)
        } catch {
            Log.app.error("License deactivation failed: \(String(describing: error), privacy: .public)")
        }
        Keychain.delete(keychainAccount)
        state = .unlicensed
        onChange?()
    }

    /// Re-checks a stored license. Network failures keep the current state.
    func revalidate() async {
        guard let stored = loadStored() else { return }
        do {
            if try await client.validate(key: stored.key, instanceID: stored.instanceID) {
                var updated = stored
                updated.validatedAt = Date()
                store(updated)
                state = .licensed(keySuffix: Self.suffix(of: stored.key))
            } else {
                revoke(String(localized: "Your license is no longer valid."))
            }
        } catch LicenseError.wrongProduct {
            revoke(String(localized: "This license key is not for SideCast."))
        } catch {
            Log.app.info("License check skipped: \(String(describing: error), privacy: .public)")
        }
        onChange?()
    }

    private func revoke(_ message: String) {
        Keychain.delete(keychainAccount)
        state = .unlicensed
        lastError = message
    }

    private func loadStored() -> Stored? {
        Keychain.read(keychainAccount).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
    }

    private func store(_ stored: Stored) {
        if let data = try? JSONEncoder().encode(stored) {
            Keychain.write(data, for: keychainAccount)
        }
    }

    private static func suffix(of key: String) -> String {
        String(key.suffix(4))
    }

    static func message(for error: Error) -> String {
        switch error as? LicenseError {
        case .notConfigured:
            String(localized: "License activation isn't available in this build yet.")
        case .rejected(let reason):
            reason.isEmpty ? String(localized: "This license key could not be activated.") : reason
        case .wrongProduct:
            String(localized: "This license key is not for SideCast.")
        case .network:
            String(localized: "Couldn't reach the license server. Check your internet connection and try again.")
        case nil:
            error.localizedDescription
        }
    }
}
#endif
