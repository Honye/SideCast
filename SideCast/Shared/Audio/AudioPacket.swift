//
//  AudioPacket.swift
//  SideCast
//
//  UDP audio datagrams. Layout:
//
//    0  UInt16  magic "SC"
//    2  UInt8   version
//    3  UInt8   codec (0 = PCM 24-bit, 1 = Opus)
//    4  UInt32  stream ID
//    8  UInt32  sequence number
//    12 UInt32  sample position of the first frame
//    16 …       ChaCha20-Poly1305 ciphertext of the encoded audio, then the 16 byte tag
//
//  The header is authenticated as associated data; the nonce is (stream ID, sequence).
//

import CryptoKit
import Foundation

nonisolated struct AudioPacketHeader: Equatable, Sendable {
    static let magic: UInt16 = 0x5343
    static let version: UInt8 = 1
    static let size = 16

    var codec: AudioCodecKind
    var streamID: UInt32
    var sequence: UInt32
    var position: UInt32

    func encoded() -> Data {
        var data = Data(count: Self.size)
        data.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: Self.magic.bigEndian, toByteOffset: 0, as: UInt16.self)
            raw.storeBytes(of: Self.version, toByteOffset: 2, as: UInt8.self)
            raw.storeBytes(of: codec.wireValue, toByteOffset: 3, as: UInt8.self)
            raw.storeBytes(of: streamID.bigEndian, toByteOffset: 4, as: UInt32.self)
            raw.storeBytes(of: sequence.bigEndian, toByteOffset: 8, as: UInt32.self)
            raw.storeBytes(of: position.bigEndian, toByteOffset: 12, as: UInt32.self)
        }
        return data
    }

    init(codec: AudioCodecKind, streamID: UInt32, sequence: UInt32, position: UInt32) {
        self.codec = codec
        self.streamID = streamID
        self.sequence = sequence
        self.position = position
    }

    init?(_ data: Data) {
        guard data.count >= Self.size else { return nil }
        let bytes = [UInt8](data.prefix(Self.size))
        func u32(_ offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        guard (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) == Self.magic,
              bytes[2] == Self.version,
              let codec = AudioCodecKind(wireValue: bytes[3]) else { return nil }
        self.codec = codec
        streamID = u32(4)
        sequence = u32(8)
        position = u32(12)
    }
}

nonisolated enum AudioPacket {
    static func seal(header: AudioPacketHeader, payload: Data, key: SymmetricKey) throws -> Data {
        let headerData = header.encoded()
        let box = try ChaChaPoly.seal(
            payload,
            using: key,
            nonce: Nonce.make(domain: header.streamID, counter: UInt64(header.sequence)),
            authenticating: headerData
        )
        return headerData + box.ciphertext + box.tag
    }

    static func open(_ datagram: Data, key: SymmetricKey) throws -> (AudioPacketHeader, Data) {
        guard let header = AudioPacketHeader(datagram), datagram.count >= AudioPacketHeader.size + 16 else {
            throw AudioCodecError.invalidPacket
        }
        let body = datagram.dropFirst(AudioPacketHeader.size)
        let box = try ChaChaPoly.SealedBox(
            nonce: Nonce.make(domain: header.streamID, counter: UInt64(header.sequence)),
            ciphertext: body.dropLast(16),
            tag: body.suffix(16)
        )
        let payload = try ChaChaPoly.open(box, using: key, authenticating: datagram.prefix(AudioPacketHeader.size))
        return (header, payload)
    }
}

extension AudioCodecKind {
    nonisolated var wireValue: UInt8 {
        switch self {
        case .pcm24: 0
        case .opus: 1
        }
    }

    nonisolated init?(wireValue: UInt8) {
        switch wireValue {
        case 0: self = .pcm24
        case 1: self = .opus
        default: return nil
        }
    }
}

/// User-facing audio mode per receiver (FR-MODE-01).
nonisolated enum AudioMode: String, Codable, CaseIterable, Sendable {
    case lowLatency
    case highQuality

    var codec: AudioCodecKind {
        switch self {
        case .lowLatency: .opus
        case .highQuality: .pcm24
        }
    }
}
