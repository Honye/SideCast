//
//  Keychain.swift
//  SideCast
//
//  Minimal generic-password Keychain access.
//

import Foundation
import os
import Security

nonisolated enum Keychain {
    static let service = "com.imarkr.SideCast"

    static func read(_ account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Log.security.error("Keychain read \(account, privacy: .public) failed: \(status)")
            }
            return nil
        }
        return result as? Data
    }

    @discardableResult
    static func write(_ data: Data, for account: String) -> Bool {
        SecItemDelete(baseQuery(account) as CFDictionary)
        var query = baseQuery(account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Log.security.error("Keychain write \(account, privacy: .public) failed: \(status)")
        }
        return status == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
