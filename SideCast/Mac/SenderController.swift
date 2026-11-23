//
//  SenderController.swift
//  SideCast
//
//  Top-level state for the Mac (sender) side: connections to receivers and per-app audio routing.
//

#if os(macOS)
import CoreAudio
import Foundation
import Network
import Observation
import os

@Observable
final class SenderController {
    let identity: LocalIdentity
    let trustStore: TrustStore
    let node: NetworkNode
    let ruleStore: RuleStore

    // MARK: Connections

    /// Live sessions (and ones still handshaking).
    private(set) var sessions: [PeerSession] = []
    /// Last failure per receiver, shown until the next attempt.
    private(set) var lastErrors: [UUID: String] = [:]

    // MARK: Audio

    /// Apps known to Core Audio, grouped by owning app.
    private(set) var apps: [AudioApp] = []
    private(set) var outputDevices: [OutputDevice] = []
    private(set) var defaultOutputUID: String?
    /// Apps whose chosen output is unavailable; they are silent until it returns (FR-ROUTE-07).
    private(set) var offlineApps: Set<String> = []
    /// Recent peak level per app (0…1), for meters.
    private(set) var levels: [String: Float] = [:]
    private(set) var audioError: String?
#if DEBUG
    private(set) var debugLines: [String] = []
#endif

    @ObservationIgnored private let router = AudioRouter()
    @ObservationIgnored private var wantedReceivers: Set<UUID> = []
    @ObservationIgnored private var reconnectWork: [UUID: DispatchWorkItem] = [:]
    @ObservationIgnored private let pairingPanel = PairingPanelController()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        identity = IdentityStore.loadOrCreate(role: .sender)
        trustStore = TrustStore()
        node = NetworkNode(identity: identity)
        ruleStore = RuleStore()
    }

    func start() {
        guard !started, !RuntimeEnvironment.isRunningTests else { return }
        started = true
        node.onIncomingConnection = { [weak self] connection in
            self?.accept(connection)
        }
        node.onPeersChanged = { [weak self] in
            self?.reconnectWantedReceivers()
        }
        node.start()
        startAudioMonitoring()
        Log.app.info("Sender started as \(self.identity.device.name, privacy: .public)")
    }

    func stop() {
        for session in sessions {
            session.close(reason: "Mac quit")
        }
        node.stop()
        pollTimer?.invalidate()
        router.stopAll()
    }

    // MARK: - Connection queries

    var receivers: [DiscoveredPeer] {
        node.peers.filter { $0.device.role == .receiver }
    }

    /// Receivers that are connected, including ones that connected to us but are not discovered.
    var connectedReceivers: [DeviceInfo] {
        sessions.filter { $0.state == .ready }.compactMap(\.peer)
    }

    func session(for peerID: UUID) -> PeerSession? {
        sessions.last { !$0.state.isClosed && ($0.peer?.id == peerID || $0.expectedPeerID == peerID) }
    }

    func status(for peerID: UUID) -> LinkStatus {
        if let session = session(for: peerID) {
            return session.state.linkStatus
        }
        if let message = lastErrors[peerID] {
            return .failed(message)
        }
        return .available
    }

    // MARK: - Connection actions

    func connect(_ peer: DiscoveredPeer) {
        wantedReceivers.insert(peer.id)
        lastErrors[peer.id] = nil
        guard session(for: peer.id) == nil else { return }
        let session = makeSession(
            transport: NWTransport(connection: node.makeConnection(to: peer)),
            isInitiator: true
        )
        session.expectedPeerID = peer.id
        session.start()
    }

    func disconnect(_ peerID: UUID) {
        wantedReceivers.remove(peerID)
        reconnectWork.removeValue(forKey: peerID)?.cancel()
        session(for: peerID)?.close(reason: "Disconnected by user")
    }

    func forget(_ peerID: UUID) {
        disconnect(peerID)
        trustStore.remove(id: peerID)
    }

    func cancelPairing(_ session: PeerSession) {
        if let id = session.peer?.id {
            wantedReceivers.remove(id)
        }
        session.close(reason: "Pairing cancelled")
    }

    // MARK: - Audio actions

    func rule(for app: AudioApp) -> AppRule {
        ruleStore.rule(for: app.id)
    }

    func setTarget(_ target: OutputTarget, for app: AudioApp) {
        ruleStore.update(app.id, name: app.name) { $0.target = target }
        applyRoutes()
    }

    func setVolume(_ volume: Double, for app: AudioApp) {
        ruleStore.update(app.id, name: app.name) { $0.volume = min(max(volume, 0), 1) }
        applyRoutes()
    }

    func setMuted(_ muted: Bool, for app: AudioApp) {
        ruleStore.update(app.id, name: app.name) { $0.muted = muted }
        applyRoutes()
    }

    func resetRule(for appID: String) {
        ruleStore.reset(appID)
        applyRoutes()
    }

    /// Apps worth showing: playing now, or with a custom rule.
    var visibleApps: [AudioApp] {
        apps.filter { $0.isPlaying || ruleStore.rules[$0.id] != nil }
            .sorted { lhs, rhs in
                if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    func displayName(for target: OutputTarget) -> String {
        switch target {
        case .systemDefault:
            String(localized: "System Default")
        case .device(let uid):
            outputDevices.first { $0.id == uid }?.name ?? String(localized: "Unavailable Device")
        case .receiver(let id):
            connectedReceivers.first { $0.id == id }?.name
                ?? trustStore.peers.first { $0.id == id }?.device.name
                ?? String(localized: "Unavailable Device")
        }
    }

    // MARK: - Audio monitoring

    private func startAudioMonitoring() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [
            kAudioHardwarePropertyProcessObjectList,
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
        ] {
            var address = CAProperty.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleAudioRefresh() }
            }
            AudioObjectAddPropertyListenerBlock(system, &address, .main, block)
            listeners.append((address, block))
        }
        // Playing state of each process changes without a list change; poll it with the meters.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        refreshAudio()
    }

    private var pollCount = 0

    private func poll() {
        for app in apps where ruleStore.rules[app.id] != nil {
            if let peak = router.takePeak(for: app.id) {
                levels[app.id] = peak
#if DEBUG
                if pollCount % 4 == 0 { DebugTrace.write("peak \(app.id) \(peak)") }
#endif
            }
        }
#if DEBUG
        debugLines = DebugTrace.recent()
#endif
        pollCount += 1
        if pollCount % 2 == 0 {
            refreshAudio()
        }
    }

    private func scheduleAudioRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refreshAudio()
        }
    }

    private func refreshAudio() {
        let scanned = AudioProcessScanner.scan()
        if scanned != apps { apps = scanned }
        let devices = OutputDeviceScanner.outputDevices()
        if devices != outputDevices { outputDevices = devices }
        let defaultUID = OutputDeviceScanner.defaultOutputDeviceUID()
        if defaultUID != defaultOutputUID { defaultOutputUID = defaultUID }
        applyRoutes()
    }

    private func applyRoutes() {
        var units: [RouteUnit] = []
        var offline: Set<String> = []
        let connected = Set(connectedReceivers.map(\.id))
        for app in apps where !app.processes.isEmpty {
            let rule = ruleStore.rule(for: app.id)
            guard !rule.isPassthrough else { continue }
            let target: RouteTarget
            switch rule.target {
            case .systemDefault:
                guard let uid = defaultOutputUID else { continue }
                target = .device(uid)
            case .device(let uid):
                if outputDevices.contains(where: { $0.id == uid }) {
                    target = .device(uid)
                } else {
                    target = .discard
                    offline.insert(app.id)
                }
            case .receiver(let id):
                if connected.contains(id) {
                    target = .receiver(id)
                } else {
                    target = .discard
                    offline.insert(app.id)
                }
            }
            units.append(RouteUnit(
                key: app.id,
                name: app.name,
                processes: app.processObjectIDs,
                target: target,
                gain: rule.muted ? 0 : Float(rule.volume)
            ))
        }
        if offline != offlineApps { offlineApps = offline }
        router.apply(units, defaultDeviceUID: defaultOutputUID)
        let message = router.lastError.map { String(describing: $0) }
        if message != audioError { audioError = message }
    }

    // MARK: - Sessions

    private func accept(_ connection: NWConnection) {
        makeSession(transport: NWTransport(connection: connection), isInitiator: false).start()
    }

    @discardableResult
    private func makeSession(transport: MessageTransport, isInitiator: Bool) -> PeerSession {
        let session = PeerSession(identity: identity, trustStore: trustStore, transport: transport, isInitiator: isInitiator)
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
        updatePairingPanel()
        switch state {
        case .ready:
            guard let peer = session.peer else { return }
            Log.net.info("Connected to \(peer.name, privacy: .public)")
            wantedReceivers.insert(peer.id)
            lastErrors[peer.id] = nil
            // Keep only the newest session per receiver.
            for other in sessions where other !== session && other.peer?.id == peer.id {
                other.close(reason: "Replaced")
            }
            applyRoutes()
        case .closed(let error):
            sessions.removeAll { $0 === session }
            applyRoutes()
            guard let peerID = session.peer?.id ?? session.expectedPeerID else { return }
            if let error {
                lastErrors[peerID] = error.userMessage
                if error.isFinal {
                    wantedReceivers.remove(peerID)
                } else {
                    scheduleReconnect(peerID)
                }
            }
        default:
            break
        }
    }

    private func handle(_ message: ControlMessage, from session: PeerSession) {
        switch message {
        case .ping(let id):
            session.send(.pong(id: id))
        default:
            Log.net.debug("Unhandled message \(String(describing: message), privacy: .public)")
        }
    }

    private func scheduleReconnect(_ peerID: UUID) {
        guard wantedReceivers.contains(peerID) else { return }
        reconnectWork[peerID]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantedReceivers.contains(peerID),
                  let peer = self.receivers.first(where: { $0.id == peerID }) else { return }
            Log.net.info("Reconnecting to \(peer.device.name, privacy: .public)")
            self.connect(peer)
        }
        reconnectWork[peerID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func reconnectWantedReceivers() {
        for peer in receivers where wantedReceivers.contains(peer.id) && session(for: peer.id) == nil {
            scheduleReconnect(peer.id)
        }
    }

    private func updatePairingPanel() {
        let pairing = sessions.first {
            if case .pairingShowCode = $0.state { return true }
            return false
        }
        if let pairing, case let .pairingShowCode(code) = pairing.state {
            pairingPanel.show(code: code, deviceName: pairing.peer?.name ?? "") { [weak self, weak pairing] in
                guard let pairing else { return }
                self?.cancelPairing(pairing)
            }
        } else {
            pairingPanel.hide()
        }
    }
}
#endif
