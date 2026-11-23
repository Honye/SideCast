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
    private static let deviceIDKey = "identity.deviceID"
    private static let keychainService = "com.imarkr.SideCast"
    private static let keychainAccount = "identity-signing-key"

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
        if let data = readKeychain(), let stored = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            key = stored
        } else {
            key = Curve25519.Signing.PrivateKey()
            writeKeychain(key.rawRepresentation)
        }

        return LocalIdentity(
            device: DeviceInfo(id: deviceID, name: DeviceName.current, platform: .current, role: role),
            signingKey: key
        )
    }

    private static func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        return query
    }

    private static func readKeychain() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Log.security.error("Keychain read failed: \(status)")
            }
            return nil
        }
        return result as? Data
    }

    private static func writeKeychain(_ data: Data) {
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Log.security.error("Keychain write failed: \(status)")
        }
    }
}
