//
//  FramingTests.swift
//  SideCastTests
//

import CryptoKit
import Foundation
import Testing
@testable import SideCast

struct FramingTests {
    @Test func decodesFramesSplitAcrossReads() throws {
        let frames = [Data("hello".utf8), Data(), Data(repeating: 7, count: 70_000)]
        let stream = frames.map(Framing.encode).reduce(Data(), +)

        var decoder = FrameDecoder()
        var decoded: [Data] = []
        var offset = 0
        while offset < stream.count {
            let end = min(offset + 1_000, stream.count)
            decoded += try decoder.append(stream.subdata(in: offset..<end))
            offset = end
        }
        #expect(decoded == frames)
    }

    @Test func rejectsOversizedFrame() {
        var decoder = FrameDecoder()
        #expect(throws: FramingError.self) {
            _ = try decoder.append(Data([0x7f, 0xff, 0xff, 0xff]))
        }
    }

    @Test func secureChannelRoundTripAndReplayRejection() throws {
        let key = SymmetricKey(size: .bits256)
        var sealer = FrameSealer(key: key)
        var opener = FrameOpener(key: key)

        let first = try sealer.seal(Data("one".utf8))
        let second = try sealer.seal(Data("two".utf8))
        #expect(try opener.open(first) == Data("one".utf8))
        #expect(try opener.open(second) == Data("two".utf8))

        // Replaying an old frame must fail.
        #expect(throws: SecureChannelError.unexpectedNonce) {
            _ = try opener.open(first)
        }
    }

    @Test func pairingProofDependsOnCodeTranscriptAndRole() {
        let transcript = Data(repeating: 1, count: 32)
        let proof = HandshakeCrypto.pairingProof(code: "123456", transcript: transcript, prover: .receiver)
        #expect(HandshakeCrypto.isValidPairingProof(proof, code: "123456", transcript: transcript, prover: .receiver))
        #expect(!HandshakeCrypto.isValidPairingProof(proof, code: "123457", transcript: transcript, prover: .receiver))
        #expect(!HandshakeCrypto.isValidPairingProof(proof, code: "123456", transcript: transcript, prover: .sender))
        #expect(!HandshakeCrypto.isValidPairingProof(proof, code: "123456", transcript: Data(repeating: 2, count: 32), prover: .receiver))
    }

    @Test func pairingCodeIsSixDigits() {
        for _ in 0..<100 {
            let code = HandshakeCrypto.generatePairingCode()
            #expect(code.count == 6)
            #expect(code.allSatisfy { $0.isNumber })
        }
    }
}
