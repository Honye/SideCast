//
//  PacketReorderBuffer.swift
//  SideCast
//
//  Puts audio packets back in order. Wi-Fi sometimes delivers a packet a little after the next
//  one; that packet isn't lost, so instead of playing silence right away the later packets are
//  held briefly to give it time to arrive. Only when it's still missing after `maxHeld` packets
//  is the gap filled with silence.
//

import Foundation

nonisolated struct PacketReorderBuffer<Payload> {
    enum Output {
        case packet(Payload)
        /// This many packets never arrived; play silence in their place.
        case missing(Int)
    }

    /// Packets held while waiting for a missing one, before giving up on it.
    let maxHeld: Int
    /// The sequence number expected next.
    private(set) var expected: UInt32?
    private var held: [UInt32: Payload] = [:]

    init(maxHeld: Int) {
        self.maxHeld = max(1, maxHeld)
    }

    /// About `duration` of audio, for packets of `framesPerPacket` frames.
    static func maxHeld(framesPerPacket: Int, sampleRate: Double = 48_000, duration: TimeInterval = 0.02) -> Int {
        max(2, Int((duration * sampleRate / Double(max(1, framesPerPacket))).rounded()))
    }

    var heldCount: Int { held.count }

    mutating func reset() {
        expected = nil
        held = [:]
    }

    /// What to play now, in order.
    mutating func insert(sequence: UInt32, payload: Payload) -> [Output] {
        guard let expected else {
            self.expected = sequence &+ 1
            return [.packet(payload)]
        }
        let ahead = Int32(bitPattern: sequence &- expected)
        if ahead < 0 { return [] } // late (already given up on) or a duplicate
        var output: [Output] = []
        if ahead == 0 {
            output.append(.packet(payload))
            self.expected = expected &+ 1
            drainHeld(into: &output)
            return output
        }
        guard held[sequence] == nil else { return [] }
        held[sequence] = payload
        guard held.count >= maxHeld else { return [] }
        // Give up on the gap: continue from the earliest packet held.
        let earliest = held.keys.min { Int32(bitPattern: $0 &- expected) < Int32(bitPattern: $1 &- expected) }!
        output.append(.missing(Int(Int32(bitPattern: earliest &- expected))))
        self.expected = earliest
        drainHeld(into: &output)
        return output
    }

    private mutating func drainHeld(into output: inout [Output]) {
        while let next = expected, let payload = held.removeValue(forKey: next) {
            output.append(.packet(payload))
            expected = next &+ 1
        }
    }
}
