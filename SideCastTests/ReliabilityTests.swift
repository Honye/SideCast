//
//  ReliabilityTests.swift
//  SideCastTests
//
//  Fixes from the test report of 2026-11-25: late audio packets, and retrying audio routes
//  after a temporary error.
//

import Foundation
import Testing
@testable import SideCast

struct PacketReorderBufferTests {
    typealias Buffer = PacketReorderBuffer<Int>

    func run(_ sequences: [UInt32], maxHeld: Int = 4) -> (played: [Int], missing: Int) {
        var buffer = Buffer(maxHeld: maxHeld)
        var played: [Int] = []
        var missing = 0
        for sequence in sequences {
            for output in buffer.insert(sequence: sequence, payload: Int(sequence)) {
                switch output {
                case .packet(let value): played.append(value)
                case .missing(let count): missing += count
                }
            }
        }
        return (played, missing)
    }

    @Test func inOrderPacketsPassStraightThrough() {
        #expect(run([10, 11, 12, 13]) == ([10, 11, 12, 13], 0))
    }

    @Test func twoSwappedPacketsCauseNoSilence() {
        // The report's case: four packets, the middle two swapped.
        #expect(run([0, 2, 1, 3]) == ([0, 1, 2, 3], 0))
    }

    @Test func aPacketThatNeverComesIsSilencedAfterTheWindow() {
        var buffer = Buffer(maxHeld: 4)
        _ = buffer.insert(sequence: 0, payload: 0)
        for sequence: UInt32 in 2...4 {
            #expect(buffer.insert(sequence: sequence, payload: Int(sequence)).isEmpty)
        }
        let output = buffer.insert(sequence: 5, payload: 5)
        guard case .missing(1) = output.first else {
            Issue.record("expected one missing packet first, got \(output)")
            return
        }
        #expect(output.count == 5)
        // Too late now: dropped.
        #expect(buffer.insert(sequence: 1, payload: 1).isEmpty)
    }

    @Test func duplicatesAreDropped() {
        #expect(run([0, 1, 1, 3, 3, 2]) == ([0, 1, 2, 3], 0))
    }

    @Test func wrapsAroundTheSequenceNumber() {
        #expect(run([UInt32.max - 1, UInt32.max, 0, 1]).missing == 0)
        #expect(run([UInt32.max, 1, 0]).played == [Int(UInt32.max), 0, 1])
    }

    @Test func windowIsAbout20Milliseconds() {
        #expect(Buffer.maxHeld(framesPerPacket: 240) == 4)   // low latency, 5 ms packets
        #expect(Buffer.maxHeld(framesPerPacket: 480) == 2)
        #expect(Buffer.maxHeld(framesPerPacket: 4_800) == 2)
    }
}

#if os(macOS)
struct RetryBackoffTests {
    @Test func retriesSoonerFirstThenUpTo30Seconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        var backoff = RetryBackoff()
        #expect(!backoff.isDue(at: start))
        backoff.recordFailure(at: start)
        #expect(!backoff.isDue(at: start.addingTimeInterval(0.5)))
        #expect(backoff.isDue(at: start.addingTimeInterval(1)))
        backoff.recordFailure(at: start)
        #expect(!backoff.isDue(at: start.addingTimeInterval(1.5)))
        #expect(backoff.isDue(at: start.addingTimeInterval(2)))
        for _ in 0..<10 { backoff.recordFailure(at: start) }
        #expect(backoff.nextAttempt == start.addingTimeInterval(RetryBackoff.maxDelay))
        backoff.recordSuccess()
        #expect(!backoff.isDue(at: start.addingTimeInterval(1_000)))
        #expect(backoff.failures == 0)
    }
}
#endif
