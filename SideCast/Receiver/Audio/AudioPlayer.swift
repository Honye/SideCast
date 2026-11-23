//
//  AudioPlayer.swift
//  SideCast
//
//  Plays the jitter buffer through AVAudioEngine. Keeps running (with silence) for as long as a
//  Mac is connected, which also keeps the app alive in the background (FR-RECV-03).
//

#if !os(macOS)
import AVFoundation
import Foundation
import os
import Synchronization

/// Real-time side: pulls from the ring with simple buffering and drift handling.
nonisolated final class PlaybackRenderer: @unchecked Sendable {
    let ring: FloatRingBuffer
    /// Frames to buffer before starting, and to aim for while playing.
    let targetFrames = Atomic<Int>(2_400)
    private var buffering = true
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8_192 * 2)

    init(ring: FloatRingBuffer) {
        self.ring = ring
    }

    deinit {
        scratch.deallocate()
    }

    func render(frameCount: Int, bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let frames = min(frameCount, 8_192)
        let target = targetFrames.load(ordering: .relaxed)
        var available = ring.available / 2

        if buffering && available >= target {
            buffering = false
        }
        var got = 0
        if !buffering {
            // Clock drift / burst: if far above target, drop a little each callback.
            let excess = available - target - frames
            if excess > target / 2 + 480 {
                let drop = min(excess, max(frames / 16, 1))
                ring.skip(drop * 2)
                available -= drop
            }
            got = ring.read(into: scratch, count: frames * 2) / 2
            if got < frames {
                buffering = true
            }
        }

        for index in 0..<buffers.count {
            guard let data = buffers[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channel = min(index, 1)
            for frame in 0..<frames {
                data[frame] = frame < got ? scratch[frame * 2 + channel] : 0
            }
        }
    }
}

final class AudioPlayer {
    let renderer: PlaybackRenderer
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private(set) var isRunning = false
    private var interruptionObserver: NSObjectProtocol?

    var volume: Float = 1 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    init(ring: FloatRingBuffer) {
        renderer = PlaybackRenderer(ring: ring)
    }

    func setTargetLatency(_ mode: AudioMode) {
        // Low latency: ~25 ms of buffer; high quality: ~120 ms to absorb Wi-Fi jitter.
        renderer.targetFrames.store(mode == .lowLatency ? 1_200 : 5_760, ordering: .relaxed)
    }

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)

        let format = AVAudioFormat(standardFormatWithSampleRate: AudioWireFormat.sampleRate, channels: 2)!
        let renderer = self.renderer
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            renderer.render(frameCount: Int(frameCount), bufferList: bufferList)
            return noErr
        }
        engine.attach(source)
        try engine.connectNode(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
        try engine.start()
        self.source = source
        isRunning = true

        // After an interruption (e.g. a phone call) resume when the system recommends it.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.resumptionRecommendationNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let context = notification.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext,
                  context.recommendation == .shouldResume else { return }
            MainActor.assumeIsolated {
                try? AVAudioSession.sharedInstance().setActive(true)
                try? self?.engine.start()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        if let source {
            engine.detach(source)
        }
        source = nil
        isRunning = false
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
