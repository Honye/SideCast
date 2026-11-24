//
//  MirrorSource.swift
//  SideCast
//
//  Where mirrored pictures come from: a Mac display through ScreenCaptureKit (with the pointer,
//  as confirmed), or in debug builds a moving test pattern that needs no screen recording
//  permission (SIDECAST_TEST_PATTERN=1).
//

#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import os
import ScreenCaptureKit

/// Delivers pixel buffers on the queue it was started with.
nonisolated protocol MirrorSource: AnyObject, Sendable {
    func start(queue: DispatchQueue, onFrame: @escaping @Sendable (CVPixelBuffer) -> Void, onStop: @escaping @Sendable (Error?) -> Void) async throws
    func stop()
}

nonisolated enum MirrorSourceError: LocalizedError {
    case displayNotFound

    var errorDescription: String? {
        String(localized: "The display isn't available any more.")
    }
}

/// Captures one display.
nonisolated final class ScreenCaptureSource: NSObject, MirrorSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    private var stream: SCStream?
    private var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    private var onStop: (@Sendable (Error?) -> Void)?

    init(displayID: CGDirectDisplayID, width: Int, height: Int) {
        self.displayID = displayID
        self.width = width
        self.height = height
    }

    func start(queue: DispatchQueue, onFrame: @escaping @Sendable (CVPixelBuffer) -> Void, onStop: @escaping @Sendable (Error?) -> Void) async throws {
        self.onFrame = onFrame
        self.onStop = onStop
        // Throws if the user hasn't allowed screen recording.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw MirrorSourceError.displayNotFound
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.queueDepth = 4
        configuration.scalesToFit = true
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        stream.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame?(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.audio.error("Screen capture stopped: \(error.localizedDescription, privacy: .public)")
        onStop?(error)
    }
}

#if DEBUG
/// A moving test pattern at 60 fps.
nonisolated final class TestPatternSource: MirrorSource, @unchecked Sendable {
    private let width: Int
    private let height: Int
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var frame = 0
    private var row: [UInt32]

    static var isEnabled: Bool { ProcessInfo.processInfo.environment["SIDECAST_TEST_PATTERN"] == "1" }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        row = [UInt32](repeating: 0, count: width)
    }

    func start(queue: DispatchQueue, onFrame: @escaping @Sendable (CVPixelBuffer) -> Void, onStop: @escaping @Sendable (Error?) -> Void) async throws {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667))
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = self.draw() else { return }
            onFrame(buffer)
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func draw() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }
        frame += 1
        // A vertical bar sweeping right, a horizontal bar sweeping down, on a dark gradient.
        let barX = (frame * 8) % width
        let barY = (frame * 4) % height
        for x in 0..<width {
            let shade = UInt32(40 + 60 * x / max(width, 1))
            row[x] = 0xFF00_0000 | (shade << 16) | (shade << 8) | (shade + 40)
        }
        for x in barX..<min(barX + width / 20, width) { row[x] = 0xFF2D_D4BF }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        row.withUnsafeBytes { bytes in
            for y in 0..<height {
                let destination = base.advanced(by: y * stride)
                if y >= barY && y < barY + height / 30 {
                    memset(destination, 0xEE, width * 4)
                } else {
                    memcpy(destination, bytes.baseAddress!, width * 4)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
#endif
#endif
