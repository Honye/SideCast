//
//  RemoteAudioStream.swift
//  SideCast
//
//  Sends the audio mixed for one receiver over UDP: collects samples from the real-time thread,
//  resamples to 48 kHz if needed, encodes, encrypts and sends packets.
//

#if os(macOS)
import AVFoundation
import CryptoKit
import Foundation
import Network
import os
import Synchronization

nonisolated final class RemoteAudioStream: AudioFrameSink, @unchecked Sendable {
    let config: StreamConfig

    private let key: SymmetricKey
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "SideCast.stream", qos: .userInteractive)
    private let ring = FloatRingBuffer(capacity: 1 << 17)
    private let sourceRate = Atomic<Int>(48_000)
    private let encoder: AudioPacketEncoder
    private var timer: DispatchSourceTimer?
    private var sequence: UInt32 = 0
    private var position: UInt32 = 0
    private var pending: [Float] = []
    private var readBuffer = [Float](repeating: 0, count: 1 << 15)
    private var resampler: AVAudioConverter?
    private var resamplerRate = 0
    private(set) var packetsSent = 0

    init(config: StreamConfig, key: SymmetricKey, host: NWEndpoint.Host, port: UInt16, interface: NWInterface?) throws {
        self.config = config
        self.key = key
        encoder = try makeEncoder(for: config.codec)
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        if let interface {
            parameters.requiredInterface = interface
        }
        parameters.serviceClass = .interactiveVoice
        connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    }

    func start() {
        connection.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.pump() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        connection.cancel()
    }

    // MARK: AudioFrameSink (real-time thread)

    func write(_ interleaved: UnsafePointer<Float>, frames: Int, sampleRate: Double) {
        sourceRate.store(Int(sampleRate), ordering: .relaxed)
        ring.write(interleaved, count: frames * 2)
    }

    // MARK: Encoder queue

    private func pump() {
        let available = ring.available & ~1
        if available > 0 {
            let count = min(available, readBuffer.count)
            let read = readBuffer.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: count) }
            let rate = sourceRate.load(ordering: .relaxed)
            if rate == Int(AudioWireFormat.sampleRate) {
                pending.append(contentsOf: readBuffer[0..<read])
            } else {
                resample(read / 2, from: rate)
            }
        }

        let packetSamples = config.framesPerPacket * 2
        while pending.count >= packetSamples {
            do {
                let encoded = try pending.withUnsafeBufferPointer { try encoder.encode($0.baseAddress!) }
                if let encoded {
                    let header = AudioPacketHeader(codec: config.codec, streamID: config.streamID, sequence: sequence, position: position)
                    let datagram = try AudioPacket.seal(header: header, payload: encoded, key: key)
                    connection.send(content: datagram, completion: .idempotent)
                    sequence &+= 1
                    packetsSent += 1
                }
            } catch {
                Log.audio.error("Encode failed: \(String(describing: error), privacy: .public)")
            }
            position &+= UInt32(config.framesPerPacket)
            pending.removeFirst(packetSamples)
        }
    }

    private func resample(_ frames: Int, from rate: Int) {
        guard frames > 0,
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 2, interleaved: true),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioWireFormat.sampleRate, channels: 2, interleaved: true)
        else { return }
        if resampler == nil || resamplerRate != rate {
            resampler = AVAudioConverter(from: inputFormat, to: outputFormat)
            resamplerRate = rate
        }
        guard let resampler,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let output = AVAudioPCMBuffer(
                  pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(Double(frames) * AudioWireFormat.sampleRate / Double(rate)) + 64
              ) else { return }
        input.frameLength = AVAudioFrameCount(frames)
        readBuffer.withUnsafeBufferPointer { source in
            input.floatChannelData![0].update(from: source.baseAddress!, count: frames * 2)
        }
        var consumed = false
        _ = resampler.convert(to: output, error: nil) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        let samples = Int(output.frameLength) * 2
        pending.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: samples))
    }
}
#endif
