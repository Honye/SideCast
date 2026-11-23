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

    @Test func removedAccountDeviceNeedsPairingUntilAllowedAgain() {
        let account = InMemoryKeyValueStore.Account()
        let macDirectory = AccountDeviceDirectory(store: InMemoryKeyValueStore(account: account), identity: macIdentity, accountAvailable: { true })
        let padDirectory = AccountDeviceDirectory(store: InMemoryKeyValueStore(account: account), identity: padIdentity, accountAvailable: { true })
        macDirectory.start()
        padDirectory.start()
        let macTrust = trustStore(directory: macDirectory)
        let padTrust = trustStore(directory: padDirectory)

        macTrust.remove(id: padIdentity.device.id)
        let (mac, _) = handshake(macTrust: macTrust, padTrust: padTrust)
        if case .pairingShowCode = mac.state {} else {
            Issue.record("expected pairing after removal, got \(mac.state)")
        }

        macTrust.allowAccountDevice(id: padIdentity.device.id)
        let (mac2, pad2) = handshake(macTrust: macTrust, padTrust: padTrust)
        #expect(mac2.state == .ready)
        #expect(pad2.state == .ready)
    }

    @Test func revocationSurvivesRelaunch() {
        let defaults = UserDefaults(suiteName: "SideCastTests.\(UUID().uuidString)")!
        let first = TrustStore(defaults: defaults)
        first.remove(id: padIdentity.device.id)
        #expect(TrustStore(defaults: defaults).revokedAccountDevices == [padIdentity.device.id])
        first.trust(padIdentity.device, identityKey: padIdentity.publicKey)
        #expect(TrustStore(defaults: defaults).revokedAccountDevices.isEmpty)
    }
}
