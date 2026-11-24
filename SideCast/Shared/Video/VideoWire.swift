//
//  VideoWire.swift
//  SideCast
//
//  Screen mirroring stream (FR-SCREEN-01). Its own TCP connection from the Mac to the receiver:
//  each frame on the wire is [UInt32 big-endian length][ChaCha20-Poly1305 sealed message], with
//  the session's video key and a running counter as nonce. A message is:
//
//    0  UInt8   kind: 0 = format (H.264 parameter sets), 1 = picture
//    1  UInt8   flags: bit 0 = key frame
//    2  UInt32  stream ID
//    6  UInt32  width   (format) / 0
//    10 UInt32  height  (format) / 0
//    14 …       format: [UInt16 length][parameter set]…; picture: AVCC data (4-byte NAL lengths)
//
//  Every key frame is preceded by a format message.
//

import CoreGraphics
import Foundation

nonisolated enum VideoMessage: Equatable, Sendable {
    case format(streamID: UInt32, width: Int, height: Int, parameterSets: [Data])
    case picture(streamID: UInt32, isKeyframe: Bool, data: Data)

    static let headerSize = 14
    /// Largest sealed message accepted (a 4K key frame is well below this).
    static let maxWireLength = 16 << 20

    var streamID: UInt32 {
        switch self {
        case .format(let id, _, _, _), .picture(let id, _, _): id
        }
    }

    func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + 64)
        func append<T: FixedWidthInteger>(_ value: T) {
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
        }
        switch self {
        case let .format(streamID, width, height, parameterSets):
            append(UInt8(0)); append(UInt8(0)); append(streamID)
            append(UInt32(width)); append(UInt32(height))
            for set in parameterSets {
                append(UInt16(set.count))
                data.append(set)
            }
        case let .picture(streamID, isKeyframe, payload):
            append(UInt8(1)); append(UInt8(isKeyframe ? 1 : 0)); append(streamID)
            append(UInt32(0)); append(UInt32(0))
            data.append(payload)
        }
        return data
    }

    init?(_ data: Data) {
        guard data.count >= Self.headerSize else { return nil }
        let base = data.startIndex
        func u32(_ offset: Int) -> UInt32 {
            data[(base + offset)..<(base + offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        let kind = data[base]
        let flags = data[base + 1]
        let streamID = u32(2)
        switch kind {
        case 0:
            var sets: [Data] = []
            var index = base + Self.headerSize
            while index + 2 <= data.endIndex {
                let length = Int(data[index]) << 8 | Int(data[index + 1])
                index += 2
                guard index + length <= data.endIndex else { return nil }
                sets.append(Data(data[index..<(index + length)]))
                index += length
            }
            guard !sets.isEmpty else { return nil }
            self = .format(streamID: streamID, width: Int(u32(6)), height: Int(u32(10)), parameterSets: sets)
        case 1:
            self = .picture(streamID: streamID, isKeyframe: flags & 1 != 0, data: Data(data[(base + Self.headerSize)...]))
        default:
            return nil
        }
    }
}

nonisolated enum MirrorSizing {
    /// Never encode more than this many pixels per side (performance, FR-SCREEN-04).
    static let maxLongSide = 3840

    /// The picture size for a display of `source` pixels shown on a receiver whose screen is
    /// `receiver` pixels: same aspect ratio as the display (no stretching), no larger than the
    /// display or the receiver screen (compared long side to long side), even dimensions.
    static func encodedSize(source: CGSize, receiver: CGSize) -> (width: Int, height: Int) {
        guard source.width > 0, source.height > 0 else { return (0, 0) }
        let sourceLong = max(source.width, source.height)
        let sourceShort = min(source.width, source.height)
        let receiverLong = max(receiver.width, receiver.height, 1)
        let receiverShort = max(min(receiver.width, receiver.height), 1)
        let scale = min(
            1,
            receiverLong / sourceLong,
            receiverShort / sourceShort,
            CGFloat(maxLongSide) / sourceLong
        )
        func even(_ value: CGFloat) -> Int { max(2, Int(value) & ~1) }
        return (even(source.width * scale), even(source.height * scale))
    }

    /// A starting bit rate for this size at 60 fps; lowered when the network can't keep up.
    static func initialBitRate(width: Int, height: Int) -> Int {
        let estimate = Double(width * height) * 60 * 0.07
        return Int(min(max(estimate, 6_000_000), 40_000_000))
    }
}

/// Mirroring to several receivers at once needs Premium on each of them (FR-SCREEN-05).
nonisolated enum MirrorPolicy {
    /// Whether `candidate` may start mirroring while `mirroring` receivers already do.
    static func allows(candidateHasPremium: Bool, othersHavePremium: [Bool]) -> Bool {
        othersHavePremium.isEmpty || (candidateHasPremium && othersHavePremium.allSatisfy { $0 })
    }
}
