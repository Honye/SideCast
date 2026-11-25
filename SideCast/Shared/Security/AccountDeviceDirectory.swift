//
//  AccountDeviceDirectory.swift
//  SideCast
//
//  Same Apple ID auto-trust (FR-CONN-05). Every device publishes its device ID and public
//  identity key to the user's own iCloud key-value store. During the handshake a peer whose
//  identity key is listed there belongs to the same Apple ID and is trusted without a pairing
//  code. Only public keys are stored; nothing about audio, apps or usage leaves the devices.
//

import Foundation
import Observation
import os

/// Storage shared by all devices signed in to the same iCloud account.
protocol AccountKeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    var keys: [String] { get }
    func synchronize()
    /// Called on the main queue when another device changed values.
    var onExternalChange: (() -> Void)? { get set }
}

nonisolated struct AccountDevice: Codable, Hashable, Sendable, Identifiable {
    var device: DeviceInfo
    var identityKey: Data
    var updatedAt: Date

    var id: UUID { device.id }
}

@Observable
final class AccountDeviceDirectory {
    static let keyPrefix = "device."

    /// Other devices signed in to the same iCloud account.
    private(set) var devices: [AccountDevice] = []
    private(set) var isAccountAvailable: Bool

    @ObservationIgnored private let store: AccountKeyValueStore
    @ObservationIgnored private let identity: LocalIdentity
    @ObservationIgnored private let accountAvailable: () -> Bool

    init(
        store: AccountKeyValueStore,
        identity: LocalIdentity,
        accountAvailable: @escaping () -> Bool = { FileManager.default.ubiquityIdentityToken != nil }
    ) {
        self.store = store
        self.identity = identity
        self.accountAvailable = accountAvailable
        isAccountAvailable = accountAvailable()
    }

    func start() {
        store.onExternalChange = { [weak self] in self?.reload() }
        publish()
        store.synchronize()
        reload()
    }

    /// True if this exact device (ID and identity key) is on the same iCloud account.
    func contains(_ device: DeviceInfo, identityKey: Data) -> Bool {
        devices.contains { $0.device.id == device.id && $0.identityKey == identityKey }
    }

    func containsDevice(id: UUID) -> Bool {
        devices.contains { $0.device.id == id }
    }

    /// Takes another device off the iCloud list, on all devices of the account. A device that is
    /// still running SideCast adds itself back (see `reload`), so it never needs a pairing code;
    /// one that isn't (e.g. an old iPad) stays off the list until it opens SideCast again.
    func remove(id: UUID) {
        guard id != identity.device.id else { return }
        store.set(nil, forKey: Self.keyPrefix + id.uuidString)
        reload()
    }

    func reload() {
        isAccountAvailable = accountAvailable()
        let ownKey = Self.keyPrefix + identity.device.id.uuidString
        let found = store.keys
            .filter { $0.hasPrefix(Self.keyPrefix) && $0 != ownKey }
            .compactMap { store.data(forKey: $0).flatMap { try? JSONDecoder().decode(AccountDevice.self, from: $0) } }
            .sorted { $0.device.name.localizedStandardCompare($1.device.name) == .orderedAscending }
        if found != devices {
            devices = found
        }
        // Another copy of this device's entry may have been overwritten (e.g. renamed device).
        if let current = store.data(forKey: ownKey).flatMap({ try? JSONDecoder().decode(AccountDevice.self, from: $0) }),
           current.identityKey == identity.publicKey, current.device == identity.device {
            return
        }
        publish()
    }

    private func publish() {
        let entry = AccountDevice(device: identity.device, identityKey: identity.publicKey, updatedAt: Date())
        if let data = try? JSONEncoder().encode(entry) {
            store.set(data, forKey: Self.keyPrefix + identity.device.id.uuidString)
        }
    }
}

/// `NSUbiquitousKeyValueStore` (iCloud key-value storage). Without the iCloud entitlement or a
/// signed-in account it simply never syncs, and SideCast falls back to pairing codes.
final class ICloudKeyValueStore: AccountKeyValueStore {
    var onExternalChange: (() -> Void)?
    private let store = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onExternalChange?() }
        }
    }

    func data(forKey key: String) -> Data? {
        store.data(forKey: key)
    }

    func set(_ data: Data?, forKey key: String) {
        if let data {
            store.set(data, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    var keys: [String] { Array(store.dictionaryRepresentation.keys) }

    func synchronize() {
        store.synchronize()
    }
}

/// In-memory store for tests. Instances created from the same `Account` see each other's
/// values, like two devices on one iCloud account.
final class InMemoryKeyValueStore: AccountKeyValueStore {
    final class Account {
        var values: [String: Data] = [:]
        var stores: [WeakStore] = []
    }

    struct WeakStore {
        weak var store: InMemoryKeyValueStore?
    }

    var onExternalChange: (() -> Void)?
    private let account: Account

    init(account: Account) {
        self.account = account
        account.stores.append(WeakStore(store: self))
    }

    func data(forKey key: String) -> Data? { account.values[key] }

    func set(_ data: Data?, forKey key: String) {
        account.values[key] = data
        for other in account.stores where other.store !== self {
            other.store?.onExternalChange?()
        }
    }

    var keys: [String] { Array(account.values.keys) }

    func synchronize() {}
}
