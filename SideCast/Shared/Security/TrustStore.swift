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
    private(set) var peers: [TrustedPeer] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey = "trust.peers"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode([TrustedPeer].self, from: data) {
            peers = stored
        }
    }

    func isTrusted(_ device: DeviceInfo, identityKey: Data) -> Bool {
        peers.contains { $0.id == device.id && $0.identityKey == identityKey }
    }

    func trust(_ device: DeviceInfo, identityKey: Data) {
        peers.removeAll { $0.id == device.id }
        peers.append(TrustedPeer(device: device, identityKey: identityKey, pairedAt: Date()))
        save()
    }

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
