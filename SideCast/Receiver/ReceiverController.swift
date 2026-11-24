//
//  ReceiverController.swift
//  SideCast
//
//  Top-level state for the receiver side (iPad / iPhone / Vision Pro, and a Mac in receive mode).
//  A receiver is connected to at most one Mac at a time (FR-CONN-10).
//

import CoreGraphics
import Foundation
import Network
import Observation
import os

/// A Mac screen being mirrored to this device (FR-SCREEN-01).
struct MirrorState: Equatable {
    var streamID: UInt32
    var macName: String
    var displayName: String
    /// Known once the first picture format arrives.
    var pictureSize: CGSize?
}

@Observable
final class ReceiverController {
    let identity: LocalIdentity
    let trustStore: TrustStore
    let node: NetworkNode
    /// Devices on the same iCloud account, trusted without a pairing code (FR-CONN-05).
    let accountDirectory: AccountDeviceDirectory

    private(set) var sessions: [PeerSession] = []
    private(set) var lastError: String?
    /// SideCast's own output volume on this device, 0…1 (FR-RECV-02).
    var volume: Double = UserDefaults.standard.object(forKey: RuntimeEnvironment.profiled("receiver.volume")) as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(volume, forKey: RuntimeEnvironment.profiled("receiver.volume"))
            player.volume = Float(volume)
        }
    }
    private(set) var currentStream: StreamConfig?
    /// The Mac screen shown here, while the Mac mirrors to this device.
    private(set) var mirror: MirrorState?
    @ObservationIgnored let mirrorRenderer = MirrorRenderer()
    /// Called when mirroring starts or stops (the Mac receiver opens / closes its window).
    @ObservationIgnored var onMirrorChanged: (() -> Void)?
    @ObservationIgnored private var videoReceiver: VideoStreamReceiver?
    @ObservationIgnored private var mirrorSessionID: UUID?
    @ObservationIgnored private var mirrorVisible = true
    /// SideCast Premium bought on this device (App Store).
    let store = StoreManager()

    /// What this receiver tells the Mac. A Mac in receive mode is always treated as Premium
    /// (PRD 4, v0.5): the Mac app has no purchases.
    var hasPremium: Bool {
#if os(macOS)
        true
#else
        store.isUnlocked
#endif
    }

    @ObservationIgnored private var started = false
    @ObservationIgnored private let ring = FloatRingBuffer(capacity: 1 << 16)
    @ObservationIgnored private lazy var player = AudioPlayer(ring: ring)
    @ObservationIgnored private var audioReceiver: AudioReceiver?
    @ObservationIgnored private var audioSessionID: UUID?
#if !os(macOS)
    // Not on the Mac: a Now Playing entry there would take over the keyboard's play/pause key.
    @ObservationIgnored private let nowPlaying = NowPlayingController()
#endif
#if DEBUG
    @ObservationIgnored private var statsTimer: Timer?
#endif

    init() {
        identity = IdentityStore.loadOrCreate(role: .receiver)
        trustStore = TrustStore()
        node = NetworkNode(identity: identity)
        accountDirectory = AccountDeviceDirectory(
            store: RuntimeEnvironment.usesICloud ? ICloudKeyValueStore() : InMemoryKeyValueStore(account: .init()),
            identity: identity
        )
        trustStore.accountTrust = { [accountDirectory] device, key in accountDirectory.contains(device, identityKey: key) }
    }

    func start() {
        guard !started, !RuntimeEnvironment.isRunningTests else { return }
        started = true
        node.onIncomingConnection = { [weak self] connection in
            self?.accept(connection)
        }
        node.start()
        accountDirectory.start()
#if !os(macOS)
        nowPlaying.onDisconnect = { [weak self] in self?.disconnect() }
        store.onChange = { [weak self] in
            guard let self else { return }
            self.activeSession?.send(.premiumStatus(unlocked: self.hasPremium))
        }
        store.start()
#endif
        Log.app.info("Receiver started as \(self.identity.device.name, privacy: .public)")
    }

    /// Disconnects and stops listening, e.g. when the Mac app quits.
    func stop() {
        disconnect()
        node.stop()
    }

    // MARK: - Queries

    var senders: [DiscoveredPeer] {
        node.peers.filter { $0.device.role == .sender }
    }

    /// The connected Mac, if any.
    var activeSession: PeerSession? {
        sessions.first { $0.state == .ready }
    }

    /// A session waiting for the user to type the pairing code.
    var pairingSession: PeerSession? {
        sessions.first { $0.state == .pairingEnterCode || $0.state == .pairingVerifying }
    }

    func status(for peerID: UUID) -> LinkStatus {
        if let session = sessions.last(where: { !$0.state.isClosed && ($0.peer?.id == peerID || $0.expectedPeerID == peerID) }) {
            return session.state.linkStatus
        }
        return .available
    }

    // MARK: - Actions

    func connect(_ peer: DiscoveredPeer) {
        lastError = nil
        guard status(for: peer.id) == .available else { return }
        let session = makeSession(
            transport: NWTransport(connection: node.makeConnection(to: peer)),
            isInitiator: true
        )
        session.expectedPeerID = peer.id
        session.start()
    }

    func disconnect() {
        for session in sessions {
            session.close(reason: "Disconnected by receiver")
        }
    }

    /// Removes trust in a Mac: it has to pair again (FR-CONN-07).
    func forget(_ peerID: UUID) {
        for session in sessions where session.peer?.id == peerID {
            session.close(reason: "Disconnected by receiver")
        }
        trustStore.remove(id: peerID)
    }

    func submitPairingCode(_ code: String) {
        pairingSession?.submitPairingCode(code)
    }

    func cancelPairing() {
        pairingSession?.close(reason: "Pairing cancelled")
    }

    // MARK: - Sessions

    private func accept(_ connection: NWConnection) {
        makeSession(transport: NWTransport(connection: connection), isInitiator: false).start()
    }

    private func makeSession(transport: MessageTransport, isInitiator: Bool) -> PeerSession {
        let session = PeerSession(identity: identity, trustStore: trustStore, transport: transport, isInitiator: isInitiator)
        session.busyCheck = { [weak self] mac in
            guard let active = self?.activeSession, let current = active.peer, current.id != mac.id else { return nil }
            return current.name
        }
        session.onStateChange = { [weak self, weak session] state in
            guard let self, let session else { return }
            self.sessionChanged(session, state: state)
        }
        session.onMessage = { [weak self, weak session] message in
            guard let self, let session else { return }
            self.handle(message, from: session)
        }
        sessions.append(session)
        return session
    }

    private func sessionChanged(_ session: PeerSession, state: PeerSession.State) {
        switch state {
        case .ready:
            guard let peer = session.peer else { return }
            Log.net.info("Connected to \(peer.name, privacy: .public)")
            lastError = nil
            for other in sessions where other !== session && other.state == .ready {
                if other.peer?.id == peer.id {
                    other.close(reason: "Replaced")
                } else {
                    // Another Mac got in first; this one has to wait.
                    session.close(reason: "Busy")
                    return
                }
            }
            session.send(.premiumStatus(unlocked: hasPremium))
            startAudio(for: session)
        case .closed(let error):
            sessions.removeAll { $0 === session }
            if audioSessionID == session.id {
                stopAudio()
            }
            if mirrorSessionID == session.id {
                endMirror()
            }
            if let error, session.isInitiator || error.isFinal {
                lastError = error.userMessage
            }
        default:
            break
        }
    }

    // MARK: - Audio

    private func startAudio(for session: PeerSession) {
        stopAudio()
        guard let key = session.audioKey else { return }
        let receiver = AudioReceiver(key: key, ring: ring)
        do {
            try receiver.start { [weak session] port in
                MainActor.assumeIsolated {
                    session?.send(.receiverInfo(audioPort: port))
                }
            }
            player.volume = Float(volume)
            try player.start()
        } catch {
            Log.audio.error("Could not start audio: \(error.localizedDescription, privacy: .public)")
            lastError = String(localized: "Could not start audio playback.")
        }
        audioReceiver = receiver
        audioSessionID = session.id
#if !os(macOS)
        nowPlaying.show(macName: session.peer?.name ?? "Mac")
#endif
#if DEBUG
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let receiver = self.audioReceiver else { return }
                DebugTrace.write("rx packets=\(receiver.packetsReceived) lost=\(receiver.packetsLost) buffered=\(self.ring.available / 2) stream=\(self.currentStream?.codec.rawValue ?? "-") engine=\(self.player.isRunning) video=\(self.videoReceiver?.messagesReceived ?? 0) shown=\(self.mirrorRenderer.framesRendered)")
            }
        }
#endif
    }

    private func stopAudio() {
#if DEBUG
        statsTimer?.invalidate()
        statsTimer = nil
#endif
        audioReceiver?.stop()
        audioReceiver = nil
        audioSessionID = nil
        currentStream = nil
        player.stop()
#if !os(macOS)
        nowPlaying.hide()
#endif
    }

    private func handle(_ message: ControlMessage, from session: PeerSession) {
        switch message {
        case .ping(let id):
            session.send(.pong(id: id))
        case .startStream(let config):
            guard session.id == audioSessionID else { return }
            ring.skip(ring.available)
            player.setTargetLatency(config.codec == .opus ? .lowLatency : .highQuality)
            audioReceiver?.setStream(config)
            currentStream = config
        case .startMirroring(let request):
            startMirror(request, session: session)
        case .stopMirroring(let streamID):
            guard mirror?.streamID == streamID else { return }
            endMirror()
        case .stopStream(let streamID):
            guard session.id == audioSessionID, currentStream?.streamID == streamID else { return }
            audioReceiver?.setStream(nil)
            currentStream = nil
        default:
            Log.net.debug("Unhandled message \(String(describing: message), privacy: .public)")
        }
    }
}

// MARK: - Screen mirroring

extension ReceiverController {
    /// The user stopped mirroring here (confirmed: the receiver may stop it, only the Mac starts it).
    func stopMirroring() {
        guard let mirror else { return }
        activeSession?.send(.stopMirroring(streamID: mirror.streamID))
        endMirror()
    }

    /// The mirrored screen went off / on screen, e.g. the app moved to the background
    /// (FR-SCREEN-07). The Mac pauses while hidden and sends a key frame when it's back.
    func setMirrorVisible(_ visible: Bool) {
        guard visible != mirrorVisible else { return }
        mirrorVisible = visible
        guard let mirror, let session = sessions.first(where: { $0.id == mirrorSessionID }) else { return }
        if visible {
            mirrorRenderer.reset()
        }
        session.send(.mirrorVisibility(streamID: mirror.streamID, visible: visible))
    }

    fileprivate func startMirror(_ request: MirrorRequest, session: PeerSession) {
        endMirror()
        guard let key = session.videoKey else { return }
        let renderer = mirrorRenderer
        renderer.reset()
        renderer.onNeedKeyframe = { [weak self, weak session] in
            guard let self, let mirror = self.mirror, self.mirrorVisible else { return }
            session?.send(.requestKeyframe(streamID: mirror.streamID))
        }
        renderer.onSize = { [weak self] size in
            self?.mirror?.pictureSize = size
        }
        let receiver = VideoStreamReceiver(key: key) { message in
            renderer.handle(message)
        }
        let maxSize = ReceiverScreen.maxPixelSize
        do {
            try receiver.start { [weak self, weak session] port in
                MainActor.assumeIsolated {
                    guard let self, let session, self.mirror?.streamID == request.streamID else { return }
                    session.send(.mirrorReady(MirrorReady(
                        streamID: request.streamID,
                        port: port,
                        maxWidth: Int(maxSize.width),
                        maxHeight: Int(maxSize.height)
                    )))
                    if !self.mirrorVisible {
                        session.send(.mirrorVisibility(streamID: request.streamID, visible: false))
                    }
                }
            }
        } catch {
            Log.net.error("Could not listen for video: \(error.localizedDescription, privacy: .public)")
            session.send(.stopMirroring(streamID: request.streamID))
            return
        }
        videoReceiver = receiver
        mirrorSessionID = session.id
        mirror = MirrorState(streamID: request.streamID, macName: session.peer?.name ?? "Mac", displayName: request.displayName)
        onMirrorChanged?()
    }

    fileprivate func endMirror() {
        guard mirror != nil || videoReceiver != nil else { return }
        videoReceiver?.stop()
        videoReceiver = nil
        mirrorSessionID = nil
        mirror = nil
        mirrorRenderer.reset()
        onMirrorChanged?()
    }
}
