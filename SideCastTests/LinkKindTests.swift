//
//  LinkKindTests.swift
//  SideCastTests
//
//  Wired first (FR-CONN-03/04): which link an interface is, and when to switch.
//

import Network
import Testing
@testable import SideCast

struct LinkKindTests {
    @Test func classifiesInterfaces() {
        #expect(LinkKind.classify(name: "anpi0", type: .other) == .wired)          // iPad / iPhone on USB
        #expect(LinkKind.classify(name: "bridge0", type: .other) == .wired)        // Thunderbolt Bridge
        #expect(LinkKind.classify(name: "en5", type: .wiredEthernet) == .wired)
        #expect(LinkKind.classify(name: "en0", type: .wifi) == .wifi)
        #expect(LinkKind.classify(name: "awdl0", type: .wifi) == .peerToPeer)
        #expect(LinkKind.classify(name: "llw0", type: .other) == .peerToPeer)
        #expect(LinkKind.classify(name: "lo0", type: .loopback) == .local)
        #expect(LinkKind.classify(name: "utun3", type: .other) == .unknown)       // VPN / proxy tunnel
    }

    @Test func prefersWired() {
        #expect(LinkKind.wired > .wifi)
        #expect(LinkKind.wifi > .peerToPeer)
    }

    @Test func switchesToWiredWhenItAppears() {
        #expect(LinkKind.shouldSwitch(current: .wifi, currentIsViable: true, best: .wired))
        #expect(LinkKind.shouldSwitch(current: .peerToPeer, currentIsViable: true, best: .wired))
    }

    @Test func staysOnAWorkingLinkOtherwise() {
        #expect(!LinkKind.shouldSwitch(current: .wired, currentIsViable: true, best: .wired))
        #expect(!LinkKind.shouldSwitch(current: .peerToPeer, currentIsViable: true, best: .wifi))
        #expect(!LinkKind.shouldSwitch(current: .unknown, currentIsViable: true, best: .wifi))  // e.g. a tunnel
        #expect(!LinkKind.shouldSwitch(current: .local, currentIsViable: true, best: .wired))
    }

    @Test func leavesALinkThatStoppedWorking() {
        // Cable pulled: switch to whatever is left.
        #expect(LinkKind.shouldSwitch(current: .unknown, currentIsViable: false, best: .wifi))
        #expect(LinkKind.shouldSwitch(current: .unknown, currentIsViable: false, best: .peerToPeer))
        // Nothing left to switch to: let the normal reconnect handle it.
        #expect(!LinkKind.shouldSwitch(current: .unknown, currentIsViable: false, best: .unknown))
    }
}
