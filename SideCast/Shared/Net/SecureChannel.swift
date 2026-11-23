//
//  SecureChannel.swift
//  SideCast
//
//  ChaCha20-Poly1305 encryption of control frames. Nonces are a running counter, so a replayed,
//  dropped or reordered frame fails to open.
//

import CryptoKit
import Foundation

nonisolated enum SecureChannelError: Error, Equatable {
    case unexpectedNonce
}

nonisolated enum Nonce {
    /// 12 byte nonce: 4 byte domain + 8 byte big-endian counter.
    static func make(domain: UInt32, counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 12)
        bytes.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: domain.bigEndian, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: counter.bigEndian, toByteOffset: 4, as: UInt64.self)
        }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}

nonisolated struct FrameSealer {
    let key: SymmetricKey
    private(set) var counter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: Nonce.make(domain: 0, counter: counter))
        counter += 1
        return box.combined
    }
}

nonisolated struct FrameOpener {
    let key: SymmetricKey
    private(set) var counter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    mutating func open(_ frame: Data) throws -> Data {
        let box = try ChaChaPoly.SealedBox(combined: frame)
        let expected = Nonce.make(domain: 0, counter: counter)
        guard box.nonce.withUnsafeBytes({ Data($0) }) == expected.withUnsafeBytes({ Data($0) }) else {
            throw SecureChannelError.unexpectedNonce
        }
        let plaintext = try ChaChaPoly.open(box, using: key)
        counter += 1
        return plaintext
    }
}
