//
//  AccountTrustTests.swift
//  SideCastTests
//

import Foundation
import Testing
@testable import SideCast

@MainActor
struct AccountTrustTests {
    let macIdentity = LocalIdentity.ephemeral(name: "Mac", platform: .mac, role: .sender)
    let padIdentity = LocalIdentity.ephemeral(name: "iPad", platform: .iPad, role: .receiver)

    func trustStore(directory: AccountDeviceDirectory) -> TrustStore {
        let store = TrustStore(defaults: UserDefaults(suiteName: "SideCastTests.\(UUID().uuidString)")!)
        store.accountTrust = { device, key in directory.contains(device, identityKey: key) }
        return store
    }

    func handshake(macTrust: TrustStore, padTrust: TrustStore) -> (PeerSession, PeerSession) {
        let link = LoopbackLink()
        let mac = PeerSession(identity: macIdentity, trustStore: macTrust, transport: link.a, isInitiator: true)
        let pad = PeerSession(identity: padIdentity, trustStore: padTrust, transport: link.b, isInitiator: false)
        mac.start()
        pad.start()
        link.drain()
        return (mac, pad)
    }

    @Test func directoriesOnOneAccountSeeEachOther() {
        let account = InMemoryKeyValueStore.Account()
        let macDirectory = AccountDeviceDirectory(store: InMemoryKeyValueStore(account: account), identity: macIdentity, accountAvailable: { true })
        let padDirectory = AccountDeviceDirectory(store: InMemoryKeyValueStore(account: account), identity: padIdentity, accountAvailable: { true })
        macDirectory.start()
        padDirectory.start()
        #expect(macDirectory.devices.map(\.id) == [padIdentity.device.id])
        #expect(padDirectory.devices.map(\.id) == [macIdentity.device.id])
        #expect(macDirectory.contains(padIdentity.device, identityKey: padIdentity.publicKey))
        // Not the same device: right ID, wrong key.
        #expect(!macDirectory.contains(padIdentity.device, identityKey: macIdentity.publicKey))
    }

    @Test func sameAppleIDConnectsWithoutPairing() {
        let account = InMemoryKeyValueStore.Account()
        let macDirectory = AccountDeviceDirectory(store: InMemoryKeyValueStore(account: account), identity: macIdentity, accountAvailable: { true })
        let padDirectory = AccountDeviceDirectory(store: InMemoryKeyValueStore(account: account), identity: padIdentity, accountAvailable: { true })
        macDirectory.start()
        padDirectory.start()
        let macTrust = trustStore(directory: macDirectory)
        let padTrust = trustStore(directory: padDirectory)

        let (mac, pad) = handshake(macTrust: macTrust, padTrust: padTrust)
        #expect(mac.state == .ready)
        #expect(pad.state == .ready)
        // Auto-trust is not stored as a pairing.
        #expect(macTrust.peers.isEmpty)
    }

    @Test func differentAccountsStillNeedPairing() {
        let macDirectory = AccountDeviceDirectory(store: InMemoryKeyValueStore(account: .init()), identity: macIdentity, accountAvailable: { true })
        let padDirectory = AccountDeviceDirectory(store: InMemoryKeyValueStore(account: .init()), identity: padIdentity, accountAvailable: { true })
        macDirectory.start()
        padDirectory.start()
        let (mac, _) = handshake(macTrust: trustStore(directory: macDirectory), padTrust: trustStore(directory: padDirectory))
        if case .pairingShowCode = mac.state {} else {
            Issue.record("expected pairing, got \(mac.state)")
        }
    }

    @Test func removingTakesTheDeviceOffTheListForTheWholeAccount() {
        let account = InMemoryKeyValueStore.Account()
        let macDirectory = AccountDeviceDirectory(store: InMemoryKeyValueStore(account: account), identity: macIdentity, accountAvailable: { true })
        let otherMac = AccountDeviceDirectory(store: InMemoryKeyValueStore(account: account), identity: LocalIdentity.ephemeral(name: "Mac 2", platform: .mac, role: .sender), accountAvailable: { true })
        macDirectory.start()
        otherMac.start()
        // An old iPad that no longer runs SideCast left its entry behind.
        let pad = AccountDevice(device: padIdentity.device, identityKey: padIdentity.publicKey, updatedAt: Date())
        InMemoryKeyValueStore(account: account).set(try? JSONEncoder().encode(pad), forKey: AccountDeviceDirectory.keyPrefix + padIdentity.device.id.uuidString)
        #expect(macDirectory.containsDevice(id: padIdentity.device.id))

        macDirectory.remove(id: padIdentity.device.id)
        #expect(!macDirectory.containsDevice(id: padIdentity.device.id))
        #expect(!otherMac.containsDevice(id: padIdentity.device.id))
        // Removing this device itself does nothing.
        macDirectory.remove(id: macIdentity.device.id)
        #expect(otherMac.containsDevice(id: macIdentity.device.id))
    }

    @Test func removedDeviceStillRunningNeedsNoPairingCode() {
        let account = InMemoryKeyValueStore.Account()
        let macDirectory = AccountDeviceDirectory(store: InMemoryKeyValueStore(account: account), identity: macIdentity, accountAvailable: { true })
        let padDirectory = AccountDeviceDirectory(store: InMemoryKeyValueStore(account: account), identity: padIdentity, accountAvailable: { true })
        macDirectory.start()
        padDirectory.start()

        macDirectory.remove(id: padIdentity.device.id)
        // The iPad, still running SideCast, puts itself back.
        #expect(macDirectory.containsDevice(id: padIdentity.device.id))
        let (mac, pad) = handshake(macTrust: trustStore(directory: macDirectory), padTrust: trustStore(directory: padDirectory))
        #expect(mac.state == .ready)
        #expect(pad.state == .ready)
    }

    @Test func forgettingAPairedDeviceDoesNotAffectSameAppleIDTrust() {
        let account = InMemoryKeyValueStore.Account()
        let macDirectory = AccountDeviceDirectory(store: InMemoryKeyValueStore(account: account), identity: macIdentity, accountAvailable: { true })
        let padDirectory = AccountDeviceDirectory(store: InMemoryKeyValueStore(account: account), identity: padIdentity, accountAvailable: { true })
        macDirectory.start()
        padDirectory.start()
        let macTrust = trustStore(directory: macDirectory)
        macTrust.remove(id: padIdentity.device.id)
        let (mac, _) = handshake(macTrust: macTrust, padTrust: trustStore(directory: padDirectory))
        #expect(mac.state == .ready)
    }

    @Test func oldRemovedListIsCleared() {
        let defaults = UserDefaults(suiteName: "SideCastTests.\(UUID().uuidString)")!
        defaults.set([padIdentity.device.id.uuidString], forKey: "trust.revokedAccountDevices")
        _ = TrustStore(defaults: defaults)
        #expect(defaults.object(forKey: "trust.revokedAccountDevices") == nil)
    }
}
