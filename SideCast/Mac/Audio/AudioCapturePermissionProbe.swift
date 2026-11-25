//
//  AudioCapturePermissionProbe.swift
//  SideCast
//
//  Asks for "System audio recording" and finds out whether it was allowed (first-launch guide,
//  FR-PERM-01). macOS has no API for this permission: it asks the first time a process tap is
//  read, and a tap without permission only delivers silence. So the probe plays an inaudible
//  tone (about -80 dB) from SideCast itself, taps SideCast's own output without muting it, and
//  reports "allowed" as soon as the tone comes through.
//

#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation
import os
import Synchronization

/// Highest level seen by the probe's I/O proc (real-time thread).
nonisolated final class ProbeMeter: @unchecked Sendable {
    private let peakBits = Atomic<UInt32>(0)

    var peak: Float { Float(bitPattern: peakBits.load(ordering: .relaxed)) }

    var ioBlock: AudioDeviceIOBlock {
        { [self] _, input, _, _, _ in
            var peak: Float = 0
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for index in 0..<Int(buffer.mDataByteSize) / 4 {
                    peak = max(peak, abs(data[index]))
                }
            }
            if peak > self.peak {
                peakBits.store(peak.bitPattern, ordering: .relaxed)
            }
        }
    }
}

final class AudioCapturePermissionProbe {
    enum Outcome {
        case allowed
        /// Denied, or the user hasn't answered yet when the probe gave up.
        case notConfirmed
    }

    /// Far below hearing, but not zero.
    static let toneAmplitude: Float = 0.000_1

    private let engine = AVAudioEngine()
    private let meter = ProbeMeter()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    /// Shows macOS's question (the first time) and waits up to `timeout` for the answer.
    func run(timeout: Duration = .seconds(60)) async -> Outcome {
        defer { stop() }
        do {
            try await start()
        } catch {
            Log.audio.error("Audio permission probe failed: \(String(describing: error), privacy: .public)")
            return .notConfirmed
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if meter.peak > 0 { return .allowed }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return .notConfirmed
    }

    private func start() async throws {
        // 1. An inaudible tone, so SideCast has an audio process to tap.
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let amplitude = Self.toneAmplitude
        var phase: Float = 0
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            for frame in 0..<Int(frameCount) {
                let value = sinf(phase) * amplitude
                phase += 2 * .pi * 440 / 48_000
                if phase > 2 * .pi { phase -= 2 * .pi }
                for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()

        // 2. SideCast's own Core Audio process object appears once it plays.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var process: AudioObjectID?
        for _ in 0..<20 where process == nil {
            process = AudioProcessScanner.processes().first { $0.pid == ownPID }?.objectID
            if process == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        guard let process, let outputUID = OutputDeviceScanner.defaultOutputDeviceUID() else {
            throw CoreAudioError(status: -1, operation: "find own audio process")
        }

        // 3. Tap it without muting, and read the tap: this is what macOS asks permission for.
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.uuid = UUID()
        description.name = "SideCast permission check"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        try CAProperty.check(AudioHardwareCreateProcessTap(description, &tapID), "create probe tap")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SideCast Permission Check",
            kAudioAggregateDeviceUIDKey: "com.imarkr.SideCast.probe.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        try CAProperty.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create probe device")
        try CAProperty.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, meter.ioBlock), "create probe IO proc")
        try CAProperty.check(AudioDeviceStart(aggregateID, procID), "start probe device")
    }

    private func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        engine.stop()
    }
}
#endif
