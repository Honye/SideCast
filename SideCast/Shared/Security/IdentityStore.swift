//
//  IdentityStore.swift
//  SideCast
//
//  The long-term identity of this device: a stable device ID and an Ed25519 signing key
//  kept in the Keychain.
//

import CryptoKit
import Foundation
import os
import Security

nonisolated struct LocalIdentity: Sendable {
    let device: DeviceInfo
    let signingKey: Curve25519.Signing.PrivateKey

    var publicKey: Data { signingKey.publicKey.rawRepresentation }

    /// An identity that is never persisted. Used by tests.
    static func ephemeral(name: String, platform: DevicePlatform, role: DeviceRole) -> LocalIdentity {
        LocalIdentity(
            device: DeviceInfo(id: UUID(), name: name, platform: platform, role: role),
            signingKey: Curve25519.Signing.PrivateKey()
        )
    }
}

enum IdentityStore {
    private static let deviceIDKey = RuntimeEnvironment.profiled("identity.deviceID")
    private static let keychainAccount = RuntimeEnvironment.profiled("identity-signing-key")

    static func loadOrCreate(role: DeviceRole) -> LocalIdentity {
        let defaults = UserDefaults.standard
        let deviceID: UUID
        if let stored = defaults.string(forKey: deviceIDKey).flatMap(UUID.init(uuidString:)) {
            deviceID = stored
        } else {
            deviceID = UUID()
            defaults.set(deviceID.uuidString, forKey: deviceIDKey)
        }

        let key: Curve25519.Signing.PrivateKey
        if let data = Keychain.read(keychainAccount), let stored = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            key = stored
        } else {
            key = Curve25519.Signing.PrivateKey()
            Keychain.write(key.rawRepresentation, for: keychainAccount)
        }

        return LocalIdentity(
            device: DeviceInfo(
                id: deviceID,
                name: RuntimeEnvironment.profile.map { "\(DeviceName.current) (\($0))" } ?? DeviceName.current,
                platform: .current,
                role: role
            ),
            signingKey: key
        )
    }
}
