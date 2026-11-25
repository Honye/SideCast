//
//  TrustStore.swift
//  SideCast
//
//  Devices this device has paired with, identified by device ID and identity key.
//

import Foundation
import Observation

nonisolated struct TrustedPeer: Codable, Hashable, Sendable, Identifiable {
    var device: DeviceInfo
    var identityKey: Data
    var pairedAt: Date

    var id: UUID { device.id }
}

@Observable
final class TrustStore {
    /// Devices paired with a code.
    private(set) var peers: [TrustedPeer] = []

    /// Same Apple ID check (FR-CONN-05), provided by `AccountDeviceDirectory`.
    @ObservationIgnored var accountTrust: ((DeviceInfo, Data) -> Bool)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey = RuntimeEnvironment.profiled("trust.peers")
    /// Before 2026-11-25, removed same-Apple-ID devices needed a pairing code again; now they
    /// are taken off the iCloud list instead, and the old list is cleared.
    @ObservationIgnored private let legacyRevokedKey = RuntimeEnvironment.profiled("trust.revokedAccountDevices")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode([TrustedPeer].self, from: data) {
            peers = stored
        }
        defaults.removeObject(forKey: legacyRevokedKey)
    }

    func isTrusted(_ device: DeviceInfo, identityKey: Data) -> Bool {
        isPaired(device, identityKey: identityKey) || isTrustedViaAccount(device, identityKey: identityKey)
    }

    func isPaired(_ device: DeviceInfo, identityKey: Data) -> Bool {
        peers.contains { $0.id == device.id && $0.identityKey == identityKey }
    }

    func isTrustedViaAccount(_ device: DeviceInfo, identityKey: Data) -> Bool {
        accountTrust?(device, identityKey) == true
    }

    func trust(_ device: DeviceInfo, identityKey: Data) {
        peers.removeAll { $0.id == device.id }
        peers.append(TrustedPeer(device: device, identityKey: identityKey, pairedAt: Date()))
        save()
    }

    /// Forgets a paired device: it must enter a pairing code again. Same-Apple-ID trust comes
    /// from the iCloud list and isn't affected.
    func remove(id: UUID) {
        peers.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(peers) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
