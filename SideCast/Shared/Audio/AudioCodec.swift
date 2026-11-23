//
//  AudioCodec.swift
//  SideCast
//
//  Network audio codecs. All audio on the wire is 48 kHz stereo.
//  - High quality mode: uncompressed 24-bit PCM (lossless for the source).
//  - Low latency mode: Opus via AudioConverter.
//

import AudioToolbox
import Foundation

nonisolated enum AudioWireFormat {
    static let sampleRate: Double = 48_000
    static let channels = 2

    static func framesPerPacket(for codec: AudioCodecKind) -> Int {
        switch codec {
        case .pcm24: 240   // 5 ms, 1440 bytes: fits in one UDP datagram
        case .opus: 480    // 10 ms
        }
    }
}

nonisolated enum AudioCodecError: Error {
    case converter(OSStatus)
    case invalidPacket
}

nonisolated protocol AudioPacketEncoder: AnyObject {
    /// Encodes exactly `framesPerPacket` interleaved stereo frames. Returns nil if the codec
    /// produced no output yet (priming).
    func encode(_ interleaved: UnsafePointer<Float>) throws -> Data?
}

nonisolated protocol AudioPacketDecoder: AnyObject {
    /// Decodes one packet into interleaved stereo floats. Returns the frame count.
    func decode(_ packet: Data, into output: UnsafeMutablePointer<Float>, maxFrames: Int) throws -> Int
}

nonisolated func makeEncoder(for codec: AudioCodecKind) throws -> AudioPacketEncoder {
    switch codec {
    case .pcm24: PCM24Codec(framesPerPacket: AudioWireFormat.framesPerPacket(for: .pcm24))
    case .opus: try OpusEncoder()
    }
}

nonisolated func makeDecoder(for codec: AudioCodecKind) throws -> AudioPacketDecoder {
    switch codec {
    case .pcm24: PCM24Codec(framesPerPacket: AudioWireFormat.framesPerPacket(for: .pcm24))
    case .opus: try OpusDecoder()
    }
}

// MARK: - PCM 24-bit

nonisolated final class PCM24Codec: AudioPacketEncoder, AudioPacketDecoder {
    let framesPerPacket: Int

    init(framesPerPacket: Int) {
        self.framesPerPacket = framesPerPacket
    }

    func encode(_ interleaved: UnsafePointer<Float>) throws -> Data? {
        let samples = framesPerPacket * AudioWireFormat.channels
        var data = Data(count: samples * 3)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<samples {
                let clamped = max(-1, min(1, interleaved[index]))
                let value = Int32((clamped * 8_388_607).rounded())
                bytes[index * 3] = UInt8(truncatingIfNeeded: value)
                bytes[index * 3 + 1] = UInt8(truncatingIfNeeded: value >> 8)
                bytes[index * 3 + 2] = UInt8(truncatingIfNeeded: value >> 16)
            }
        }
        return data
    }

    func decode(_ packet: Data, into output: UnsafeMutablePointer<Float>, maxFrames: Int) throws -> Int {
        let samples = packet.count / 3
        guard samples % AudioWireFormat.channels == 0 else { throw AudioCodecError.invalidPacket }
        let frames = min(samples / AudioWireFormat.channels, maxFrames)
        packet.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<(frames * AudioWireFormat.channels) {
                let value = Int32(bytes[index * 3]) | Int32(bytes[index * 3 + 1]) << 8 | Int32(Int8(bitPattern: bytes[index * 3 + 2])) << 16
                output[index] = Float(value) / 8_388_607
            }
        }
        return frames
    }
}

// MARK: - Opus

private nonisolated func pcmFormat() -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: AudioWireFormat.sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8,
        mFramesPerPacket: 1,
        mBytesPerFrame: 8,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )
}

private nonisolated func opusFormat() -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: AudioWireFormat.sampleRate,
        mFormatID: kAudioFormatOpus,
        mFormatFlags: 0,
        mBytesPerPacket: 0,
        mFramesPerPacket: UInt32(AudioWireFormat.framesPerPacket(for: .opus)),
        mBytesPerFrame: 0,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 0,
        mReserved: 0
    )
}

/// Status returned by input callbacks when they have no more data for this call.
private nonisolated let noMoreInput: OSStatus = 0x6E6F_6D6F // 'nomo'

nonisolated final class OpusEncoder: AudioPacketEncoder {
    static let bitRate: UInt32 = 160_000
    private var converter: AudioConverterRef?
    private let frames = AudioWireFormat.framesPerPacket(for: .opus)
    private let output = UnsafeMutableRawPointer.allocate(byteCount: 4_000, alignment: 16)
    fileprivate var pendingInput: UnsafePointer<Float>?

    init() throws {
        var input = pcmFormat()
        var output = opusFormat()
        let status = AudioConverterNew(&input, &output, &converter)
        guard status == noErr else { throw AudioCodecError.converter(status) }
        var bitRate = Self.bitRate
        AudioConverterSetProperty(converter!, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitRate)
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        output.deallocate()
    }

    func encode(_ interleaved: UnsafePointer<Float>) throws -> Data? {
        guard let converter else { return nil }
        pendingInput = interleaved
        var packets: UInt32 = 1
        var description = AudioStreamPacketDescription()
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 4_000, mData: output)
        )
        let status = AudioConverterFillComplexBuffer(
            converter,
            opusEncoderInput,
            Unmanaged.passUnretained(self).toOpaque(),
            &packets,
            &list,
            &description
        )
        guard status == noErr || status == noMoreInput else { throw AudioCodecError.converter(status) }
        guard packets > 0, list.mBuffers.mDataByteSize > 0 else { return nil }
        return Data(bytes: output, count: Int(list.mBuffers.mDataByteSize))
    }

    fileprivate var framesPerPacket: Int { frames }
}

private nonisolated func opusEncoderInput(
    _ converter: AudioConverterRef,
    _ packetCount: UnsafeMutablePointer<UInt32>,
    _ data: UnsafeMutablePointer<AudioBufferList>,
    _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    let encoder = Unmanaged<OpusEncoder>.fromOpaque(userData!).takeUnretainedValue()
    guard let input = encoder.pendingInput else {
        packetCount.pointee = 0
        return noMoreInput
    }
    encoder.pendingInput = nil
    let frames = encoder.framesPerPacket
    data.pointee.mNumberBuffers = 1
    data.pointee.mBuffers.mNumberChannels = 2
    data.pointee.mBuffers.mDataByteSize = UInt32(frames * 8)
    data.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: input)
    packetCount.pointee = UInt32(frames)
    return noErr
}

nonisolated final class OpusDecoder: AudioPacketDecoder {
    private var converter: AudioConverterRef?
    fileprivate var pendingPacket: Data?
    fileprivate var packetDescription = AudioStreamPacketDescription()

    init() throws {
        var input = opusFormat()
        var output = pcmFormat()
        let status = AudioConverterNew(&input, &output, &converter)
        guard status == noErr else { throw AudioCodecError.converter(status) }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }

    func decode(_ packet: Data, into output: UnsafeMutablePointer<Float>, maxFrames: Int) throws -> Int {
        guard let converter else { return 0 }
        pendingPacket = packet
        var frames = UInt32(min(maxFrames, AudioWireFormat.framesPerPacket(for: .opus)))
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: frames * 8, mData: UnsafeMutableRawPointer(output))
        )
        let status = packet.withUnsafeBytes { _ in
            AudioConverterFillComplexBuffer(
                converter,
                opusDecoderInput,
                Unmanaged.passUnretained(self).toOpaque(),
                &frames,
                &list,
                nil
            )
        }
        pendingPacket = nil
        guard status == noErr || status == noMoreInput else { throw AudioCodecError.converter(status) }
        return Int(frames)
    }

    /// Keeps the packet bytes alive while the converter reads them.
    fileprivate var packetStorage: UnsafeMutableRawPointer?
}

private nonisolated func opusDecoderInput(
    _ converter: AudioConverterRef,
    _ packetCount: UnsafeMutablePointer<UInt32>,
    _ data: UnsafeMutablePointer<AudioBufferList>,
    _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    let decoder = Unmanaged<OpusDecoder>.fromOpaque(userData!).takeUnretainedValue()
    guard let packet = decoder.pendingPacket else {
        packetCount.pointee = 0
        return noMoreInput
    }
    decoder.pendingPacket = nil
    decoder.packetStorage?.deallocate()
    let storage = UnsafeMutableRawPointer.allocate(byteCount: max(packet.count, 1), alignment: 16)
    packet.copyBytes(to: storage.assumingMemoryBound(to: UInt8.self), count: packet.count)
    decoder.packetStorage = storage
    decoder.packetDescription = AudioStreamPacketDescription(
        mStartOffset: 0,
        mVariableFramesInPacket: 0,
        mDataByteSize: UInt32(packet.count)
    )
    data.pointee.mNumberBuffers = 1
    data.pointee.mBuffers.mNumberChannels = 2
    data.pointee.mBuffers.mDataByteSize = UInt32(packet.count)
    data.pointee.mBuffers.mData = storage
    packetCount.pointee = 1
    if let descriptions {
        withUnsafeMutablePointer(to: &decoder.packetDescription) { descriptions.pointee = $0 }
    }
    return noErr
}
