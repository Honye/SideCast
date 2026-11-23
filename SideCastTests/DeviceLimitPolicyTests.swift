//
//  DeviceLimitPolicyTests.swift
//  SideCastTests
//

#if os(macOS)
import Foundation
import Testing
@testable import SideCast

struct DeviceLimitPolicyTests {
    let now = Date()
    let long = Date().addingTimeInterval(-60)

    func connection(_ premium: Bool?, since: Date? = nil) -> DeviceLimitPolicy.Connection {
        .init(id: UUID(), hasPremium: premium, readySince: since ?? long)
    }

    @Test func oneUnpaidDeviceIsAllowed() {
        #expect(DeviceLimitPolicy.connectionsToClose([connection(false)], now: now).isEmpty)
    }

    @Test func secondUnpaidDeviceIsClosedNotTheFirst() {
        let first = connection(false)
        let second = connection(false)
        #expect(DeviceLimitPolicy.connectionsToClose([first, second], now: now) == [second.id])
    }

    @Test func paidDevicesDontCount() {
        let connections = [connection(true), connection(false), connection(true), connection(true)]
        #expect(DeviceLimitPolicy.connectionsToClose(connections, now: now).isEmpty)
    }

    @Test func newDeviceGetsAGracePeriodToReportItsStatus() {
        let unpaid = connection(false)
        let pending = connection(nil, since: now.addingTimeInterval(-0.5))
        #expect(DeviceLimitPolicy.connectionsToClose([unpaid, pending], now: now).isEmpty)
        // After the grace period, an unknown status counts as unpaid.
        let late = DeviceLimitPolicy.Connection(id: pending.id, hasPremium: nil, readySince: now.addingTimeInterval(-5))
        #expect(DeviceLimitPolicy.connectionsToClose([unpaid, late], now: now) == [late.id])
    }
}
#endif
