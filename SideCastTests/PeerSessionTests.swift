//
//  PeerSessionTests.swift
//  SideCastTests
//

import Foundation
import Testing
@testable import SideCast

@MainActor
struct PeerSessionTests {
    let macIdentity = LocalIdentity.ephemeral(name: "Mac", platform: .mac, role: .sender)
    let padIdentity = LocalIdentity.ephemeral(name: "iPad", platform: .iPad, role: .receiver)
    let macTrust = PeerSessionTests.freshTrustStore()
    let padTrust = PeerSessionTests.freshTrustStore()

    static func freshTrustStore() -> TrustStore {
        TrustStore(defaults: UserDefaults(suiteName: "SideCastTests.\(UUID().uuidString)")!)
    }

    /// Connects a Mac and an iPad session over an in-memory link and runs the handshake.
    func connect(padInitiates: Bool = false, configure: (PeerSession, PeerSession) -> Void = { _, _ in })
        -> (mac: PeerSession, pad: PeerSession, link: LoopbackLink) {
        let link = LoopbackLink()
        let mac = PeerSession(identity: macIdentity, trustStore: macTrust, transport: link.a, isInitiator: !padInitiates)
        let pad = PeerSession(identity: padIdentity, trustStore: padTrust, transport: link.b, isInitiator: padInitiates)
        configure(mac, pad)
        mac.start()
        pad.start()
        link.drain()
        return (mac, pad, link)
    }

    func pairingCode(of session: PeerSession) -> String? {
        if case let .pairingShowCode(code) = session.state { return code }
        return nil
    }

    @Test(arguments: [false, true])
    func firstConnectionPairsThenReconnectIsAutomatic(padInitiates: Bool) throws {
        let (mac, pad, link) = connect(padInitiates: padInitiates)
        let code = try #require(pairingCode(of: mac))
        #expect(pad.state == .pairingEnterCode)

        pad.submitPairingCode(code)
        link.drain()
        #expect(mac.state == .ready)
        #expect(pad.state == .ready)
        #expect(mac.peer?.id == padIdentity.device.id)
        #expect(pad.peer?.id == macIdentity.device.id)
        #expect(macTrust.peers.map(\.id) == [padIdentity.device.id])
        #expect(padTrust.peers.map(\.id) == [macIdentity.device.id])

        // Both sides derived the same audio key.
        let macAudioKey = try #require(mac.audioKey)
        let padAudioKey = try #require(pad.audioKey)
        #expect(macAudioKey == padAudioKey)

        // Messages flow after pairing.
        var received: [ControlMessage] = []
        mac.onMessage = { received.append($0) }
        pad.send(.receiverInfo(audioPort: 4242))
        link.drain()
        #expect(received == [.receiverInfo(audioPort: 4242)])

        // The same two devices reconnect without pairing.
        let (mac2, pad2, _) = connect(padInitiates: padInitiates)
        #expect(mac2.state == .ready)
        #expect(pad2.state == .ready)
    }

    @Test func wrongCodeFailsAndTrustsNobody() throws {
        let (mac, pad, link) = connect()
        let code = try #require(pairingCode(of: mac))
        pad.submitPairingCode(code == "000000" ? "111111" : "000000")
        link.drain()
        #expect(mac.state == .closed(.pairingFailed))
        #expect(pad.state.isClosed)
        #expect(macTrust.peers.isEmpty)
        #expect(padTrust.peers.isEmpty)
    }

    @Test func expiredCodeIsRejected() throws {
        let (mac, pad, link) = connect()
        let code = try #require(pairingCode(of: mac))
        mac.now = { Date().addingTimeInterval(PeerSession.pairingCodeLifetime + 1) }
        pad.submitPairingCode(code)
        link.drain()
        #expect(mac.state == .closed(.pairingExpired))
        #expect(macTrust.peers.isEmpty)
    }

    @Test func recordsWhyThePeerSaidGoodbye() throws {
        let (mac, pad, link) = connect()
        pad.submitPairingCode(try #require(pairingCode(of: mac)))
        link.drain()
        #expect(mac.state == .ready)
        // The user disconnected on the iPad: the Mac must know, so it doesn't reconnect.
        pad.close(reason: GoodbyeReason.userDisconnected)
        link.drain()
        #expect(mac.state == .closed(nil))
        #expect(mac.peerGoodbyeReason == GoodbyeReason.userDisconnected)
        #expect(pad.peerGoodbyeReason == nil)
    }

    @Test func busyReceiverRejectsAnotherMac() {
        macTrust.trust(padIdentity.device, identityKey: padIdentity.publicKey)
        padTrust.trust(macIdentity.device, identityKey: macIdentity.publicKey)
        let (mac, pad, _) = connect { _, pad in
            pad.busyCheck = { _ in "Other Mac" }
        }
        #expect(mac.state == .closed(.peerBusy("Other Mac")))
        #expect(pad.state.isClosed)
    }

    @Test func trustRemovedOnOneSideTriggersPairing() throws {
        // The receiver still trusts the Mac, but the Mac removed the receiver.
        padTrust.trust(macIdentity.device, identityKey: macIdentity.publicKey)
        let (mac, pad, link) = connect()
        let code = try #require(pairingCode(of: mac))
        pad.submitPairingCode(code)
        link.drain()
        #expect(mac.state == .ready)
        #expect(pad.state == .ready)
    }

    @Test func sameDeviceIDWithDifferentKeyMustPair() {
        // The Mac trusts a device with the iPad's ID but another identity key.
        let otherKey = LocalIdentity.ephemeral(name: "x", platform: .iPad, role: .receiver).publicKey
        macTrust.trust(padIdentity.device, identityKey: otherKey)
        padTrust.trust(macIdentity.device, identityKey: macIdentity.publicKey)
        let (mac, _, _) = connect()
        #expect(pairingCode(of: mac) != nil)
    }

    @Test func goodbyeClosesBothSides() throws {
        let (mac, pad, link) = connect()
        pad.submitPairingCode(try #require(pairingCode(of: mac)))
        link.drain()
        pad.close()
        link.drain()
        #expect(pad.state == .closed(nil))
        #expect(mac.state.isClosed)
    }
}
