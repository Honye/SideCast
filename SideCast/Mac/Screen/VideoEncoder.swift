//
//  VideoEncoder.swift
//  SideCast
//
//  Hardware H.264 encoding for screen mirroring, in VideoToolbox's low-latency mode (no frame
//  reordering, key frames on request).
//

#if os(macOS)
import CoreMedia
import Foundation
import os
import Synchronization
import VideoToolbox

nonisolated enum VideoEncoderError: Error {
    case cannotCreate(OSStatus)
}

nonisolated final class VideoEncoder: @unchecked Sendable {
    let width: Int
    let height: Int
    private let streamID: UInt32
    private let session: VTCompressionSession
    private let forceKeyframe = Atomic<Bool>(true)
    private let output: @Sendable (VideoMessage) -> Void

    /// `output` is called on VideoToolbox's thread with a format message before every key frame,
    /// then the picture.
    init(width: Int, height: Int, bitRate: Int, streamID: UInt32, output: @escaping @Sendable (VideoMessage) -> Void) throws {
        self.width = width
        self.height = height
        self.streamID = streamID
        self.output = output
        var created: VTCompressionSession?
        let specification = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else { throw VideoEncoderError.cannotCreate(status) }
        session = created
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        // Key frames only when needed (start, receiver request); screens are mostly static.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 60 as CFNumber)
        setBitRate(bitRate)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    func setBitRate(_ bitRate: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)
    }

    func requestKeyframe() {
        forceKeyframe.store(true, ordering: .relaxed)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        let keyframe = forceKeyframe.exchange(false, ordering: .relaxed)
        let properties = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: time,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self, status == noErr, let sampleBuffer else { return }
            self.emit(sampleBuffer)
        }
        if status != noErr {
            Log.audio.error("Video encode failed: \(status)")
            if keyframe { requestKeyframe() }
        }
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        guard let block = sampleBuffer.dataBuffer else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if isKeyframe, let format = sampleBuffer.formatDescription {
            output(.format(streamID: streamID, width: width, height: height, parameterSets: Self.parameterSets(format)))
        }
        var data = Data(count: block.dataLength)
        let copied = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: block.dataLength, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return }
        output(.picture(streamID: streamID, isKeyframe: isKeyframe, data: data))
    }

    private static func parameterSets(_ format: CMFormatDescription) -> [Data] {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        )
        return (0..<count).compactMap { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
    }
}
#endif
