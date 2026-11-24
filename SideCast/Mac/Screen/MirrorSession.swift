//
//  MirrorSession.swift
//  SideCast
//
//  Mirrors one Mac display to one receiver (FR-SCREEN-01): capture → H.264 → encrypted TCP.
//  When the network falls behind, frames are skipped before encoding (so the picture never
//  breaks) and the bit rate is lowered; it creeps back up while the network keeps up (7.1).
//

#if os(macOS)
import AppKit
import CoreGraphics
import CoreMedia
import CryptoKit
import Foundation
import Network
import os

nonisolated final class MirrorPipeline: @unchecked Sendable {
    let queue = DispatchQueue(label: "SideCast.mirror", qos: .userInteractive)
    let encoder: VideoEncoder
    let sender: VideoStreamSender

    /// Frames waiting to be sent before new ones are skipped.
    private static let maxBacklog = 2
    private static let minBitRate = 2_000_000

    private var visible = true
    private var lastBuffer: CVPixelBuffer?
    private var lastEncode = Date.distantPast
    private var timer: DispatchSourceTimer?
    private let maxBitRate: Int
    private var bitRate: Int
    private var goodSeconds = 0
    private var encodedInWindow = 0
    private var skippedInWindow = 0

    init(encoder: VideoEncoder, sender: VideoStreamSender, bitRate: Int) {
        self.encoder = encoder
        self.sender = sender
        self.bitRate = bitRate
        maxBitRate = bitRate
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            lastBuffer = nil
        }
    }

    /// From the source, on `queue`.
    func frame(_ buffer: CVPixelBuffer) {
        lastBuffer = buffer
        guard visible else { return }
        guard sender.backlog <= Self.maxBacklog else {
            skippedInWindow += 1
            return
        }
        encode(buffer)
    }

    func setVisible(_ visible: Bool) {
        queue.async { [self] in
            self.visible = visible
            if visible { sendKeyframe() }
        }
    }

    func requestKeyframe() {
        queue.async { [self] in sendKeyframe() }
    }

    private func sendKeyframe() {
        encoder.requestKeyframe()
        // The screen may be static, so don't wait for the next captured frame.
        if let lastBuffer, visible { encode(lastBuffer) }
    }

    private func encode(_ buffer: CVPixelBuffer) {
        encoder.encode(buffer, time: CMClockGetTime(CMClockGetHostTimeClock()))
        lastEncode = Date()
        encodedInWindow += 1
    }

    private func tick() {
        // Re-send the last picture now and then while the screen is static, so a picture lost
        // on the way is replaced.
        if visible, let lastBuffer, Date().timeIntervalSince(lastEncode) > 1, sender.backlog == 0 {
            encode(lastBuffer)
        }
        if skippedInWindow > 3 {
            bitRate = max(Int(Double(bitRate) * 0.75), Self.minBitRate)
            encoder.setBitRate(bitRate)
            goodSeconds = 0
        } else {
            goodSeconds += 1
            if goodSeconds >= 5, bitRate < maxBitRate {
                bitRate = min(Int(Double(bitRate) * 1.15), maxBitRate)
                encoder.setBitRate(bitRate)
                goodSeconds = 0
            }
        }
#if DEBUG
        DebugTrace.write("mirror \(encoder.width)x\(encoder.height) encoded=\(encodedInWindow) skipped=\(skippedInWindow) backlog=\(sender.backlog) kbps=\(bitRate / 1000)")
#endif
        encodedInWindow = 0
        skippedInWindow = 0
    }
}

/// Main-actor handle for one mirroring stream.
final class MirrorSession {
    let receiverID: UUID
    let streamID: UInt32
    let displayID: CGDirectDisplayID
    private let source: MirrorSource
    private let pipeline: MirrorPipeline
    /// The stream ended by itself (network or capture failure).
    var onEnd: ((Error?) -> Void)?

    init(
        receiverID: UUID,
        displayID: CGDirectDisplayID,
        ready: MirrorReady,
        key: SymmetricKey,
        host: NWEndpoint.Host,
        interface: NWInterface?
    ) throws {
        self.receiverID = receiverID
        self.streamID = ready.streamID
        self.displayID = displayID
        let size = MirrorSizing.encodedSize(
            source: MirrorDisplays.pixelSize(of: displayID),
            receiver: CGSize(width: ready.maxWidth, height: ready.maxHeight)
        )
        let bitRate = MirrorSizing.initialBitRate(width: size.width, height: size.height)
        let sender = VideoStreamSender(key: key, host: host, port: ready.port, interface: interface)
        let encoder = try VideoEncoder(width: size.width, height: size.height, bitRate: bitRate, streamID: ready.streamID) { message in
            sender.send(message)
        }
        pipeline = MirrorPipeline(encoder: encoder, sender: sender, bitRate: bitRate)
#if DEBUG
        if TestPatternSource.isEnabled {
            source = TestPatternSource(width: size.width, height: size.height)
        } else {
            source = ScreenCaptureSource(displayID: displayID, width: size.width, height: size.height)
        }
#else
        source = ScreenCaptureSource(displayID: displayID, width: size.width, height: size.height)
#endif
        sender.onFailure = { [weak self] in self?.end(nil) }
        Log.audio.info("Mirroring display \(displayID) at \(size.width)x\(size.height), \(bitRate / 1000) kbps")
    }

    func start() async throws {
        pipeline.sender.start()
        pipeline.start()
        let pipeline = self.pipeline
        let ended: @MainActor (Error?) -> Void = { [weak self] error in self?.end(error) }
        try await source.start(
            queue: pipeline.queue,
            onFrame: { buffer in pipeline.frame(buffer) },
            onStop: { error in
                Task { @MainActor in ended(error) }
            }
        )
    }

    func setVisible(_ visible: Bool) {
        pipeline.setVisible(visible)
    }

    func requestKeyframe() {
        pipeline.requestKeyframe()
    }

    func stop() {
        onEnd = nil
        source.stop()
        pipeline.stop()
        pipeline.sender.stop()
    }

    private func end(_ error: Error?) {
        let onEnd = self.onEnd
        stop()
        onEnd?(error)
    }
}

/// The Mac's displays, for the mirroring menu.
enum MirrorDisplays {
    struct Display: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
    }

    static var available: [Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Display(id: CGDirectDisplayID(number.uint32Value), name: screen.localizedName)
        }
    }

    static func name(of id: CGDirectDisplayID) -> String {
        available.first { $0.id == id }?.name ?? String(localized: "Display")
    }

    /// The display's current size in pixels.
    static func pixelSize(of id: CGDirectDisplayID) -> CGSize {
        if let mode = CGDisplayCopyDisplayMode(id) {
            return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        return CGSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
    }
}
#endif
