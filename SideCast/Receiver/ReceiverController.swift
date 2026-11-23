//
//  ReceiverController.swift
//  SideCast
//
//  Top-level state for the receiver side (iPad / iPhone / Vision Pro).
//  A receiver is connected to at most one Mac at a time (FR-CONN-10).
//

#if !os(macOS)
import Foundation
import Network
import Observation
import os

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
    var volume: Double = UserDefaults.standard.object(forKey: "receiver.volume") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(volume, forKey: "receiver.volume")
            player.volume = Float(volume)
        }
    }
    private(set) var currentStream: StreamConfig?
    /// SideCast Premium bought on this device (App Store).
    let store = StoreManager()

    @ObservationIgnored private var started = false
    @ObservationIgnored private let ring = FloatRingBuffer(capacity: 1 << 16)
    @ObservationIgnored private lazy var player = AudioPlayer(ring: ring)
    @ObservationIgnored private var audioReceiver: AudioReceiver?
    @ObservationIgnored private var audioSessionID: UUID?
    @ObservationIgnored private let nowPlaying = NowPlayingController()
#if DEBUG
    @ObservationIgnored private var statsTimer: Timer?
#endif

    init() {
        identity = IdentityStore.loadOrCreate(role: .receiver)
        trustStore = TrustStore()
        node = NetworkNode(identity: identity)
        accountDirectory = AccountDeviceDirectory(
            store: RuntimeEnvironment.isRunningTests ? InMemoryKeyValueStore(account: .init()) : ICloudKeyValueStore(),
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
        nowPlaying.onDisconnect = { [weak self] in self?.disconnect() }
        store.onChange = { [weak self] in
            guard let self else { return }
            self.activeSession?.send(.premiumStatus(unlocked: self.store.isUnlocked))
        }
        store.start()
        Log.app.info("Receiver started as \(self.identity.device.name, privacy: .public)")
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
            session.send(.premiumStatus(unlocked: store.isUnlocked))
            startAudio(for: session)
        case .closed(let error):
            sessions.removeAll { $0 === session }
            if audioSessionID == session.id {
                stopAudio()
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
        nowPlaying.show(macName: session.peer?.name ?? "Mac")
#if DEBUG
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let receiver = self.audioReceiver else { return }
                DebugTrace.write("rx packets=\(receiver.packetsReceived) lost=\(receiver.packetsLost) buffered=\(self.ring.available / 2) stream=\(self.currentStream?.codec.rawValue ?? "-") engine=\(self.player.isRunning)")
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
        nowPlaying.hide()
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
        case .stopStream(let streamID):
            guard session.id == audioSessionID, currentStream?.streamID == streamID else { return }
            audioReceiver?.setStream(nil)
            currentStream = nil
        default:
            Log.net.debug("Unhandled message \(String(describing: message), privacy: .public)")
        }
    }
}
#endif
