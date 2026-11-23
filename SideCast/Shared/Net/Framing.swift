//
//  Framing.swift
//  SideCast
//
//  Length-prefixed frames on the TCP control channel: [UInt32 big-endian length][payload].
//

import Foundation

nonisolated enum FramingError: Error, Equatable {
    case frameTooLarge(Int)
}

nonisolated enum Framing {
    static let maxFrameLength = 1 << 20

    static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        return Data(bytes: &length, count: 4) + payload
    }
}

nonisolated struct FrameDecoder {
    private var buffer = Data()

    /// Appends received bytes and returns every complete frame.
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length <= Framing.maxFrameLength else {
                throw FramingError.frameTooLarge(length)
            }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return frames
    }
}
