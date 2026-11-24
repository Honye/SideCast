//
//  MirrorRenderer.swift
//  SideCast
//
//  Shows the mirrored screen: H.264 from the video stream, decoded and displayed by an
//  AVSampleBufferDisplayLayer as soon as each picture arrives (no extra buffering, 7.1). The layer
//  keeps the Mac display's aspect ratio inside any view (FR-SCREEN-04).
//

import AVFoundation
import CoreMedia
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import Foundation
import os
import Synchronization

nonisolated final class MirrorRenderer: @unchecked Sendable {
    let layer: AVSampleBufferDisplayLayer
    /// Asks the Mac for a key frame (decoder lost track). Called on the main queue.
    var onNeedKeyframe: (@MainActor () -> Void)?
    /// The picture size, once known. Called on the main queue.
    var onSize: (@MainActor (CGSize) -> Void)?

    // The 27.2 SDK deprecates these calls in favour of AVSampleBufferVideoRenderer.Receiver, but
    // that API's symbols differ between 27.0 and 27.2 (the app crashed at launch on iOS 27.0), so
    // the long-standing calls stay until the minimum system is 27.2.
    private let renderer: AVSampleBufferVideoRenderer
    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var waitingForKeyframe = true
    private var lastKeyframeRequest = Date.distantPast
    private let renderedCount = Atomic<Int>(0)

    var framesRendered: Int { renderedCount.load(ordering: .relaxed) }

    @MainActor
    init() {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        renderer = layer.sampleBufferRenderer
    }

    /// Starts over for a new stream, or after the picture was hidden.
    func reset() {
        lock.withLock {
            renderer.flush()
            format = nil
            waitingForKeyframe = true
        }
    }

    /// From the video stream's queue.
    func handle(_ message: VideoMessage) {
        switch message {
        case let .format(_, width, height, parameterSets):
            let format = Self.makeFormat(parameterSets)
            lock.withLock { self.format = format }
            DispatchQueue.main.async { [onSize] in onSize?(CGSize(width: width, height: height)) }
        case let .picture(_, isKeyframe, data):
            let shown: Bool = lock.withLock {
                if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                    renderer.flush()
                    waitingForKeyframe = true
                }
                if isKeyframe { waitingForKeyframe = false }
                guard !waitingForKeyframe, let format, let sample = Self.makeSample(data, format: format) else {
                    return false
                }
                renderer.enqueue(sample)
                return true
            }
            if shown {
                renderedCount.add(1, ordering: .relaxed)
            } else {
                askForKeyframe()
            }
        }
    }

    private func askForKeyframe() {
        // At most a few requests per second while waiting.
        let now = Date()
        let ask: Bool = lock.withLock {
            guard now.timeIntervalSince(lastKeyframeRequest) > 0.3 else { return false }
            lastKeyframeRequest = now
            return true
        }
        guard ask else { return }
        DispatchQueue.main.async { [onNeedKeyframe] in onNeedKeyframe?() }
    }

    private static func makeFormat(_ parameterSets: [Data]) -> CMVideoFormatDescription? {
        let bytes = parameterSets.map { [UInt8]($0) }
        var format: CMVideoFormatDescription?
        let status: OSStatus = bytes.withUnsafeBufferPointers { pointers in
            let sizes = bytes.map(\.count)
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &format
            )
        }
        if status != noErr {
            Log.net.error("Bad video format: \(status)")
        }
        return format
    }

    private static func makeSample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }
}

nonisolated private extension Array where Element == [UInt8] {
    /// Calls `body` with stable pointers to every element's bytes.
    func withUnsafeBufferPointers<R>(_ body: ([UnsafePointer<UInt8>]) -> R) -> R {
        func recurse(_ index: Int, _ collected: [UnsafePointer<UInt8>]) -> R {
            guard index < count else { return body(collected) }
            return self[index].withUnsafeBufferPointer { buffer in
                recurse(index + 1, collected + [buffer.baseAddress!])
            }
        }
        return recurse(0, [])
    }
}

/// The receiver's screen in pixels, landscape, for the Mac to size the picture.
enum ReceiverScreen {
    @MainActor
    static var maxPixelSize: CGSize {
#if os(macOS)
        let screen = NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let size = screen?.frame.size ?? CGSize(width: 1920, height: 1080)
        return landscape(CGSize(width: size.width * scale, height: size.height * scale))
#elseif os(visionOS)
        return CGSize(width: 3840, height: 2160)
#else
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        return landscape(screen?.nativeBounds.size ?? CGSize(width: 2732, height: 2048))
#endif
    }

    private static func landscape(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width, size.height), height: min(size.width, size.height))
    }
}
