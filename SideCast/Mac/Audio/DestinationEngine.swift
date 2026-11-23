//
//  DestinationEngine.swift
//  SideCast
//
//  One output destination: a private aggregate device made of a clock/output device plus the
//  process taps of every app routed there.
//

#if os(macOS)
import CoreAudio
import Foundation
import os

final class DestinationEngine {
    struct Member {
        let key: String
        let tap: ProcessTap
        let gain: Float
    }

    struct Output: Equatable {
        /// Device used as clock and, when `writesToOutput`, as the speaker.
        let deviceUID: String
        let writesToOutput: Bool
        let sink: AudioFrameSink?

        static func == (lhs: Output, rhs: Output) -> Bool {
            lhs.deviceUID == rhs.deviceUID && lhs.writesToOutput == rhs.writesToOutput && lhs.sink === rhs.sink
        }
    }

    private(set) var memberKeys: [String] = []
    private var builtTapUIDs: [String] = []
    private var builtOutput: Output?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let mixer = AudioMixer()

    deinit {
        MainActor.assumeIsolated { teardown() }
    }

    func update(members: [Member], output: Output) throws {
        precondition(members.count <= AudioMixer.maxSlots)
        for (slot, member) in members.enumerated() {
            mixer.targetGains[slot] = member.gain
        }
        let tapUIDs = members.map(\.tap.uid)
        memberKeys = members.map(\.key)
        guard tapUIDs != builtTapUIDs || output != builtOutput else { return }
        try rebuild(members: members, output: output)
    }

    /// Highest sample level of a member since the last call (0…1).
    func takePeak(for key: String) -> Float? {
        guard let slot = memberKeys.firstIndex(of: key) else { return nil }
        let peak = mixer.peaks[slot]
        mixer.peaks[slot] = 0
        return peak
    }

    func stop() {
        teardown()
        memberKeys = []
    }

    private func rebuild(members: [Member], output: Output) throws {
        teardown()
        guard !members.isEmpty else { return }

        var tapList: [[String: Any]] = []
        for (slot, member) in members.enumerated() {
            let format = try member.tap.format()
            let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            mixer.tapBufferCounts[slot] = nonInterleaved ? Int(format.mChannelsPerFrame) : 1
            tapList.append([
                kAudioSubTapUIDKey: member.tap.uid,
                kAudioSubTapDriftCompensationKey: true,
            ])
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SideCast Destination",
            kAudioAggregateDeviceUIDKey: "com.imarkr.SideCast.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output.deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.deviceUID]],
            kAudioAggregateDeviceTapListKey: tapList,
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        try CAProperty.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
            "create aggregate device"
        )
        self.aggregateID = aggregateID

        let inputBuffers = try CAProperty.bufferChannelCounts(aggregateID, scope: kAudioObjectPropertyScopeInput)
        let tapBuffers = (0..<members.count).reduce(0) { $0 + mixer.tapBufferCounts[$1] }
        mixer.slotCount = members.count
        mixer.firstTapBuffer = max(0, inputBuffers.count - tapBuffers)
        mixer.writesToOutput = output.writesToOutput
        mixer.sink = output.sink
        mixer.sampleRate = (try? CAProperty.value(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(48_000))) ?? 48_000
        mixer.resetGains()

        var procID: AudioDeviceIOProcID?
        try CAProperty.check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, mixer.ioBlock),
            "create IO proc"
        )
        self.procID = procID
        try CAProperty.check(AudioDeviceStart(aggregateID, procID), "start aggregate device")

        builtTapUIDs = members.map(\.tap.uid)
        builtOutput = output
        Log.audio.info("Destination \(output.deviceUID, privacy: .public): \(members.count) app(s), \(inputBuffers.count) input buffers, \(self.mixer.sampleRate) Hz")
        DebugTrace.write("destination \(output.deviceUID) writes=\(output.writesToOutput) members=\(members.map(\.key)) inputBuffers=\(inputBuffers) firstTap=\(mixer.firstTapBuffer)")
    }

    private func teardown() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        mixer.slotCount = 0
        mixer.sink = nil
        builtTapUIDs = []
        builtOutput = nil
    }
}
#endif
