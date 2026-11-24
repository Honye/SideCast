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
    /// Same-Apple-ID devices the user removed; they need a pairing code again.
    private(set) var revokedAccountDevices: Set<UUID> = []

    /// Same Apple ID check (FR-CONN-05), provided by `AccountDeviceDirectory`.
    @ObservationIgnored var accountTrust: ((DeviceInfo, Data) -> Bool)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey = RuntimeEnvironment.profiled("trust.peers")
    @ObservationIgnored private let revokedKey = RuntimeEnvironment.profiled("trust.revokedAccountDevices")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode([TrustedPeer].self, from: data) {
            peers = stored
        }
        if let revoked = defaults.stringArray(forKey: revokedKey) {
            revokedAccountDevices = Set(revoked.compactMap(UUID.init(uuidString:)))
        }
    }

    func isTrusted(_ device: DeviceInfo, identityKey: Data) -> Bool {
        isPaired(device, identityKey: identityKey) || isTrustedViaAccount(device, identityKey: identityKey)
    }

    func isPaired(_ device: DeviceInfo, identityKey: Data) -> Bool {
        peers.contains { $0.id == device.id && $0.identityKey == identityKey }
    }

    func isTrustedViaAccount(_ device: DeviceInfo, identityKey: Data) -> Bool {
        !revokedAccountDevices.contains(device.id) && accountTrust?(device, identityKey) == true
    }

    func trust(_ device: DeviceInfo, identityKey: Data) {
        peers.removeAll { $0.id == device.id }
        peers.append(TrustedPeer(device: device, identityKey: identityKey, pairedAt: Date()))
        revokedAccountDevices.remove(device.id)
        save()
    }

    /// Forgets a device: a paired device must pair again, and a same-Apple-ID device is no
    /// longer trusted automatically until it pairs or is allowed again.
    func remove(id: UUID) {
        peers.removeAll { $0.id == id }
        revokedAccountDevices.insert(id)
        save()
    }

    /// Trusts a removed same-Apple-ID device automatically again.
    func allowAccountDevice(id: UUID) {
        revokedAccountDevices.remove(id)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(peers) {
            defaults.set(data, forKey: storageKey)
        }
        defaults.set(revokedAccountDevices.map(\.uuidString), forKey: revokedKey)
    }
}
