//
//  MirroringTests.swift
//  SideCastTests
//
//  Screen mirroring (FR-SCREEN): wire format, picture size, the "several devices" rule and the
//  encrypted video connection.
//

import CoreGraphics
import CryptoKit
import Foundation
import Network
import Testing
@testable import SideCast

struct VideoWireTests {
    @Test func formatRoundTrips() {
        let message = VideoMessage.format(streamID: 7, width: 2420, height: 1570, parameterSets: [Data([0x67, 1, 2, 3]), Data([0x68, 9])])
        #expect(VideoMessage(message.encoded()) == message)
    }

    @Test func pictureRoundTrips() {
        let payload = Data((0..<5000).map { UInt8($0 & 0xFF) })
        for keyframe in [true, false] {
            let message = VideoMessage.picture(streamID: 42, isKeyframe: keyframe, data: payload)
            #expect(VideoMessage(message.encoded()) == message)
        }
    }

    @Test func garbageIsRejected() {
        #expect(VideoMessage(Data([1, 2, 3])) == nil)
        #expect(VideoMessage(Data([9] + [UInt8](repeating: 0, count: 20))) == nil)
        // A format whose parameter set runs past the end.
        var truncated = VideoMessage.format(streamID: 1, width: 2, height: 2, parameterSets: [Data([1, 2, 3, 4])]).encoded()
        truncated.removeLast()
        #expect(VideoMessage(truncated) == nil)
    }
}

struct MirrorSizingTests {
    @Test func fitsReceiverKeepingAspectRatio() {
        // 16:10-ish MacBook display on a 4:3 iPad (landscape size reported).
        let size = MirrorSizing.encodedSize(source: CGSize(width: 3456, height: 2234), receiver: CGSize(width: 2420, height: 1668))
        #expect(size.width == 2420)
        #expect(abs(Double(size.width) / Double(size.height) - 3456.0 / 2234.0) < 0.01)
        #expect(size.height <= 1668)
    }

    @Test func neverUpscales() {
        let size = MirrorSizing.encodedSize(source: CGSize(width: 1920, height: 1080), receiver: CGSize(width: 2732, height: 2048))
        #expect(size.width == 1920 && size.height == 1080)
    }

    @Test func receiverOrientationDoesNotMatter() {
        let landscape = MirrorSizing.encodedSize(source: CGSize(width: 2880, height: 1800), receiver: CGSize(width: 2556, height: 1179))
        let portrait = MirrorSizing.encodedSize(source: CGSize(width: 2880, height: 1800), receiver: CGSize(width: 1179, height: 2556))
        #expect(landscape == portrait)
    }

    @Test func capsHugeDisplaysAndKeepsEvenSizes() {
        let size = MirrorSizing.encodedSize(source: CGSize(width: 6016, height: 3385), receiver: CGSize(width: 7680, height: 4320))
        #expect(size.width <= MirrorSizing.maxLongSide)
        #expect(size.width % 2 == 0 && size.height % 2 == 0)
    }
}

struct MirrorPolicyTests {
    @Test func firstMirrorIsAlwaysAllowed() {
        #expect(MirrorPolicy.allows(candidateHasPremium: false, othersHavePremium: []))
    }

    @Test func severalNeedPremiumOnEach() {
        #expect(MirrorPolicy.allows(candidateHasPremium: true, othersHavePremium: [true]))
        #expect(!MirrorPolicy.allows(candidateHasPremium: false, othersHavePremium: [true]))
        #expect(!MirrorPolicy.allows(candidateHasPremium: true, othersHavePremium: [false]))
        #expect(!MirrorPolicy.allows(candidateHasPremium: true, othersHavePremium: [true, false]))
    }
}

struct VideoStreamTests {
    /// Sends messages over a real local TCP connection and checks they arrive intact, in order.
    @Test func messagesArriveEncryptedAndInOrder() async throws {
        let key = SymmetricKey(size: .bits256)
        let received = Received()
        let receiver = VideoStreamReceiver(key: key) { message in
            received.append(message)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            do {
                try receiver.start { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        let sender = VideoStreamSender(key: key, host: "127.0.0.1", port: port, interface: nil)
        sender.start()
        let messages: [VideoMessage] = [.format(streamID: 1, width: 4, height: 2, parameterSets: [Data([1, 2])])]
            + (0..<20).map { .picture(streamID: 1, isKeyframe: $0 == 0, data: Data(repeating: UInt8($0), count: 10_000 + $0)) }
        messages.forEach(sender.send)
        for _ in 0..<100 where received.count < messages.count {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(received.messages == messages)
        sender.stop()
        receiver.stop()
    }

    @Test func wrongKeyIsDropped() async throws {
        let received = Received()
        let receiver = VideoStreamReceiver(key: SymmetricKey(size: .bits256)) { received.append($0) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            do {
                try receiver.start { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        let sender = VideoStreamSender(key: SymmetricKey(size: .bits256), host: "127.0.0.1", port: port, interface: nil)
        sender.start()
        sender.send(.picture(streamID: 1, isKeyframe: true, data: Data([1, 2, 3])))
        try await Task.sleep(for: .milliseconds(300))
        #expect(received.count == 0)
        sender.stop()
        receiver.stop()
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [VideoMessage] = []

    func append(_ message: VideoMessage) { lock.withLock { storage.append(message) } }
    var messages: [VideoMessage] { lock.withLock { storage } }
    var count: Int { lock.withLock { storage.count } }
}
