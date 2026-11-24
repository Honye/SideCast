//
//  ExtendedDisplayTests.swift
//  SideCastTests
//
//  Extended display (FR-SCREEN-02): display sizes and the request message.
//

import CoreGraphics
import Foundation
import Testing
@testable import SideCast

struct ExtendedDisplayTests {
#if os(macOS)
    @Test func startsAtTheReceiversOwnSizeWithMoreSpaceOptions() {
        // iPad Pro 11-inch: 2420 × 1668 pixels.
        let modes = ExtendedDisplayLayout.modes(receiverPixels: CGSize(width: 2420, height: 1668))
        #expect(modes.first == CGSize(width: 1210, height: 834))
        #expect(modes.count == 3)
        #expect(modes.allSatisfy { Int($0.width) % 2 == 0 && Int($0.height) % 2 == 0 })
        #expect(zip(modes, modes.dropFirst()).allSatisfy { $0.width < $1.width })
    }

    @Test func isLandscapeEvenForAPortraitReport() {
        let modes = ExtendedDisplayLayout.modes(receiverPixels: CGSize(width: 1179, height: 2556))  // iPhone
        #expect(modes[0].width > modes[0].height)
        #expect(modes[0] == CGSize(width: 1278, height: 590))
    }

    @Test func serialNumberIsStablePerReceiver() {
        let a = UUID()
        #expect(ExtendedDisplayLayout.serialNumber(for: a) == ExtendedDisplayLayout.serialNumber(for: a))
        #expect(ExtendedDisplayLayout.serialNumber(for: a) != 0)
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        #expect(ExtendedDisplayLayout.serialNumber(for: zero) == 1)
    }

    @Test func onlyTheWebsiteVersionExtends() {
        #expect(VirtualDisplay.isSupported == (RuntimeEnvironment.distribution == .website))
    }
#endif

    @Test func extendedRequestRoundTrips() throws {
        let message = ControlMessage.startMirroring(MirrorRequest(streamID: 3, displayName: "", extended: true))
        #expect(try JSONDecoder().decode(ControlMessage.self, from: JSONEncoder().encode(message)) == message)
    }

    @Test func requestWithoutTheFlagIsAMirror() throws {
        let json = Data(#"{"streamID":5,"displayName":"Built-in Display"}"#.utf8)
        let request = try JSONDecoder().decode(MirrorRequest.self, from: json)
        #expect(!request.extended)
        #expect(request.displayName == "Built-in Display")
    }
}
