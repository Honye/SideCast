//
//  MacReceiveModeTests.swift
//  SideCastTests
//
//  A Mac in receive mode (FR-RECV-07) connects to another Mac like any receiver.
//

import Foundation
import Testing
@testable import SideCast

@MainActor
struct MacReceiveModeTests {
    @Test func macSenderPairsWithMacReceiver() throws {
        let sender = LocalIdentity.ephemeral(name: "MacBook", platform: .mac, role: .sender)
        let receiver = LocalIdentity.ephemeral(name: "iMac", platform: .mac, role: .receiver)
        let link = LoopbackLink()
        let macSender = PeerSession(identity: sender, trustStore: PeerSessionTests.freshTrustStore(), transport: link.a, isInitiator: false)
        let macReceiver = PeerSession(identity: receiver, trustStore: PeerSessionTests.freshTrustStore(), transport: link.b, isInitiator: true)
        macSender.start()
        macReceiver.start()
        link.drain()

        guard case let .pairingShowCode(code) = macSender.state else {
            Issue.record("Expected a pairing code, got \(macSender.state)")
            return
        }
        macReceiver.submitPairingCode(code)
        link.drain()
        #expect(macSender.state == .ready)
        #expect(macReceiver.state == .ready)
        #expect(macSender.peer?.platform == .mac)
        #expect(macSender.peer?.role == .receiver)
    }

    @Test func twoSendersCannotConnect() {
        let one = LocalIdentity.ephemeral(name: "A", platform: .mac, role: .sender)
        let two = LocalIdentity.ephemeral(name: "B", platform: .mac, role: .sender)
        let link = LoopbackLink()
        let a = PeerSession(identity: one, trustStore: PeerSessionTests.freshTrustStore(), transport: link.a, isInitiator: true)
        let b = PeerSession(identity: two, trustStore: PeerSessionTests.freshTrustStore(), transport: link.b, isInitiator: false)
        a.start()
        b.start()
        link.drain()
        #expect(a.state.isClosed)
        #expect(b.state.isClosed)
    }
}
