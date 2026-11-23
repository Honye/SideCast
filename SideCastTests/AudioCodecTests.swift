//
//  AudioCodecTests.swift
//  SideCastTests
//

import CryptoKit
import Foundation
import Testing
@testable import SideCast

struct AudioCodecTests {
    /// A 1 kHz stereo sine at -6 dB, `frames` long.
    func sine(frames: Int, offset: Int = 0) -> [Float] {
        (0..<frames).flatMap { index -> [Float] in
            let value = Float(0.5 * sin(2 * Double.pi * 1_000 * Double(index + offset) / 48_000))
            return [value, value]
        }
    }

    @Test func pcm24RoundTrip() throws {
        let codec = PCM24Codec(framesPerPacket: 240)
        let input = sine(frames: 240)
        let packet = try #require(try input.withUnsafeBufferPointer { try codec.encode($0.baseAddress!) })
        #expect(packet.count == 240 * 2 * 3)
        var output = [Float](repeating: 0, count: 480)
        let frames = try output.withUnsafeMutableBufferPointer { try codec.decode(packet, into: $0.baseAddress!, maxFrames: 240) }
        #expect(frames == 240)
        for (a, b) in zip(input, output) {
            #expect(abs(a - b) < 1e-6)
        }
    }

    @Test func opusRoundTripKeepsTheSignal() throws {
        let encoder = try OpusEncoder()
        let decoder = try OpusDecoder()
        var decodedEnergy: Float = 0
        var packets = 0
        for chunk in 0..<50 {
            let input = sine(frames: 480, offset: chunk * 480)
            guard let packet = try input.withUnsafeBufferPointer({ try encoder.encode($0.baseAddress!) }) else { continue }
            packets += 1
            #expect(packet.count < 1_000)
            var output = [Float](repeating: 0, count: 960)
            let frames = try output.withUnsafeMutableBufferPointer { try decoder.decode(packet, into: $0.baseAddress!, maxFrames: 480) }
            // The decoder may emit fewer frames for the first packets (codec priming).
            #expect(frames <= 480)
            if chunk > 10 {
                #expect(frames == 480)
                decodedEnergy += output.reduce(0) { $0 + $1 * $1 }
            }
        }
        #expect(packets > 40)
        // RMS of a 0.5 sine is ~0.35; allow codec loss.
        let rms = sqrt(decodedEnergy / Float(39 * 960))
        #expect(rms > 0.25 && rms < 0.45)
    }
}

struct AudioPacketTests {
    @Test func sealOpenRoundTripAndTamperDetection() throws {
        let key = SymmetricKey(size: .bits256)
        let header = AudioPacketHeader(codec: .opus, streamID: 7, sequence: 42, position: 20_160)
        let payload = Data((0..<100).map { UInt8($0) })
        let datagram = try AudioPacket.seal(header: header, payload: payload, key: key)
        let (openedHeader, openedPayload) = try AudioPacket.open(datagram, key: key)
        #expect(openedHeader == header)
        #expect(openedPayload == payload)

        // Changing the sequence number in the header must break authentication.
        var tampered = datagram
        tampered[11] ^= 1
        #expect(throws: (any Error).self) { _ = try AudioPacket.open(tampered, key: key) }
        // So must the wrong key.
        #expect(throws: (any Error).self) { _ = try AudioPacket.open(datagram, key: SymmetricKey(size: .bits256)) }
    }

    @Test func ringBufferWrapsAndReportsAvailability() {
        let ring = FloatRingBuffer(capacity: 8)
        let input: [Float] = [1, 2, 3, 4, 5, 6]
        #expect(input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 6) } == 6)
        var output = [Float](repeating: 0, count: 8)
        #expect(output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 4) } == 4)
        #expect(Array(output.prefix(4)) == [1, 2, 3, 4])
        // Wraps around the end of the storage; only 6 of 7 fit.
        #expect(input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 6) } == 6)
        #expect(ring.available == 8)
        #expect(output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 8) } == 8)
        #expect(output == [5, 6, 1, 2, 3, 4, 5, 6])
    }
}
