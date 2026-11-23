//
//  AudioMixer.swift
//  SideCast
//
//  Real-time part of a destination: mixes the taps of an aggregate device into stereo, applies
//  per-app gain, and writes the result to the output device or hands it to a sink (network).
//  Runs on the Core Audio I/O thread: no allocation, no locks.
//

#if os(macOS)
import CoreAudio
import Foundation

/// Receives mixed stereo audio on the real-time thread. Implementations must not block.
nonisolated protocol AudioFrameSink: AnyObject, Sendable {
    /// - Parameter interleaved: `frames * 2` samples, L R L R …
    func write(_ interleaved: UnsafePointer<Float>, frames: Int, sampleRate: Double)
}

nonisolated final class AudioMixer: @unchecked Sendable {
    static let maxSlots = 64
    static let maxFrames = 8192
    /// Per-sample smoothing toward the target gain, avoids clicks on volume changes.
    private static let gainSmoothing: Float = 0.002

    // Written by the main thread, read on the I/O thread.
    let targetGains = UnsafeMutablePointer<Float>.allocate(capacity: maxSlots)
    // Written on the I/O thread, read and reset by the main thread.
    let peaks = UnsafeMutablePointer<Float>.allocate(capacity: maxSlots)

    // Configuration; only changed while the I/O proc is stopped.
    var slotCount = 0
    var firstTapBuffer = 0
    let tapBufferCounts = UnsafeMutablePointer<Int>.allocate(capacity: maxSlots)
    var writesToOutput = true
    var sink: AudioFrameSink?
    var sampleRate: Double = 48_000

    private let currentGains = UnsafeMutablePointer<Float>.allocate(capacity: maxSlots)
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)

    init() {
        targetGains.initialize(repeating: 1, count: Self.maxSlots)
        currentGains.initialize(repeating: 1, count: Self.maxSlots)
        peaks.initialize(repeating: 0, count: Self.maxSlots)
        tapBufferCounts.initialize(repeating: 1, count: Self.maxSlots)
        scratch.initialize(repeating: 0, count: Self.maxFrames * 2)
    }

    deinit {
        targetGains.deallocate()
        currentGains.deallocate()
        peaks.deallocate()
        tapBufferCounts.deallocate()
        scratch.deallocate()
    }

    /// Call before starting the I/O proc.
    func resetGains() {
        for slot in 0..<Self.maxSlots {
            currentGains[slot] = targetGains[slot]
            peaks[slot] = 0
        }
    }

    var ioBlock: AudioDeviceIOBlock {
        { [self] _, input, _, output, _ in
            render(input: input, output: output)
        }
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        var frames = 0
        if slotCount > 0, firstTapBuffer < inputs.count {
            let buffer = inputs[firstTapBuffer]
            frames = Int(buffer.mDataByteSize) / (4 * max(1, Int(buffer.mNumberChannels)))
        }
        frames = min(frames, Self.maxFrames)
        scratch.update(repeating: 0, count: max(frames, 1) * 2)

        var bufferIndex = firstTapBuffer
        for slot in 0..<slotCount {
            let count = tapBufferCounts[slot]
            guard count > 0, bufferIndex + count <= inputs.count else { break }
            let target = targetGains[slot]
            var gain = currentGains[slot]
            var peak: Float = 0

            if count == 1 {
                let buffer = inputs[bufferIndex]
                let channels = Int(buffer.mNumberChannels)
                if channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                    let n = min(frames, Int(buffer.mDataByteSize) / (4 * channels))
                    for frame in 0..<n {
                        let left = data[frame * channels]
                        let right = channels > 1 ? data[frame * channels + 1] : left
                        gain += (target - gain) * Self.gainSmoothing
                        scratch[2 * frame] += left * gain
                        scratch[2 * frame + 1] += right * gain
                        peak = max(peak, abs(left), abs(right))
                    }
                }
            } else {
                let leftBuffer = inputs[bufferIndex]
                let rightBuffer = inputs[bufferIndex + 1]
                if let left = leftBuffer.mData?.assumingMemoryBound(to: Float.self),
                   let right = rightBuffer.mData?.assumingMemoryBound(to: Float.self) {
                    let n = min(frames, Int(leftBuffer.mDataByteSize) / 4, Int(rightBuffer.mDataByteSize) / 4)
                    for frame in 0..<n {
                        gain += (target - gain) * Self.gainSmoothing
                        scratch[2 * frame] += left[frame] * gain
                        scratch[2 * frame + 1] += right[frame] * gain
                        peak = max(peak, abs(left[frame]), abs(right[frame]))
                    }
                }
            }
            currentGains[slot] = gain
            if peak > peaks[slot] {
                peaks[slot] = peak
            }
            bufferIndex += count
        }

        for index in 0..<outputs.count {
            if let data = outputs[index].mData {
                memset(data, 0, Int(outputs[index].mDataByteSize))
            }
        }

        if writesToOutput {
            var channel = 0
            for index in 0..<outputs.count {
                let buffer = outputs[index]
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = min(frames, Int(buffer.mDataByteSize) / (4 * channels))
                for offset in 0..<channels {
                    let source = channel + offset
                    guard source < 2 else { break }
                    for frame in 0..<n {
                        data[frame * channels + offset] = scratch[2 * frame + source]
                    }
                }
                channel += channels
                if channel >= 2 { break }
            }
        } else if frames > 0 {
            sink?.write(scratch, frames: frames, sampleRate: sampleRate)
        }
    }
}
#endif
