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
    /// Devices on the same iCloud account, trusted without a pairing code (FR-CONN-05).
    let accountDirectory: AccountDeviceDirectory
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
    /// Routed apps that claim to play have produced only silence for a while: the audio
    /// capture permission may be missing (FR-PERM-02).
    private(set) var capturedSilenceSuspected = false
#if DEBUG
    private(set) var debugLines: [String] = []
#endif

    // MARK: Premium (PRD 4, FR-PAY)

    /// Premium status reported by each connected receiver (App Store purchase on that device).
    var receiverPremium: [UUID: Bool] = [:]
    /// Keys routed to a receiver that hasn't bought Premium; they stay silent (FR-PAY-01).
    private(set) var premiumRequired: Set<String> = []
    /// Where the sound of apps without their own setting goes (FR-ROUTE-03). The only route an
    /// unpaid receiver can take.
    var allAudioTarget: OutputTarget = SenderController.loadAllAudioTarget() {
        didSet {
            if let data = try? JSONEncoder().encode(allAudioTarget) {
                UserDefaults.standard.set(data, forKey: "routing.freeTarget")
            }
            applyRoutes()
        }
    }
    /// Asks the UI to explain that a feature needs Premium.
    @ObservationIgnored var onUpgradeNeeded: ((UpgradeReason) -> Void)?
    @ObservationIgnored var ownProcessObjects: [AudioObjectID] = []
    @ObservationIgnored var readySince: [UUID: Date] = [:]
    @ObservationIgnored var premiumStatusReceived: Set<UUID> = []

    /// Audio mode per receiver (FR-MODE-01), remembered across launches (FR-MODE-04).
    private(set) var audioModes: [UUID: AudioMode] = SenderController.loadAudioModes()

    @ObservationIgnored private let router = AudioRouter()
    @ObservationIgnored private var audioPorts: [UUID: UInt16] = [:]
    @ObservationIgnored private var streams: [UUID: RemoteAudioStream] = [:]
    @ObservationIgnored private var nextStreamID = UInt32.random(in: 1...UInt32.max / 2)
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
        accountDirectory = AccountDeviceDirectory(
            store: RuntimeEnvironment.isRunningTests ? InMemoryKeyValueStore(account: .init()) : ICloudKeyValueStore(),
            identity: identity
        )
        ruleStore = RuleStore()
        router.sinkProvider = { [weak self] id in self?.streams[id] }
        trustStore.accountTrust = { [accountDirectory] device, key in accountDirectory.contains(device, identityKey: key) }
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
        accountDirectory.start()
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
        streams.values.forEach { $0.stop() }
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
    //
    // Rules are keyed by app ID, or in advanced mode by "<app ID>#<process kind>" for one kind
    // of helper process inside an app (FR-ROUTE-10).

    func rule(forKey key: String) -> AppRule {
        ruleStore.rule(for: key)
    }

    func setTarget(_ target: OutputTarget, forKey key: String, name: String) {
        ruleStore.update(key, name: name) { $0.target = target }
        applyRoutes()
    }

    func setVolume(_ volume: Double, forKey key: String, name: String) {
        ruleStore.update(key, name: name) { $0.volume = min(max(volume, 0), 1) }
        applyRoutes()
    }

    func setMuted(_ muted: Bool, forKey key: String, name: String) {
        ruleStore.update(key, name: name) { $0.muted = muted }
        applyRoutes()
    }

    func resetRule(forKey key: String) {
        ruleStore.reset(key)
        applyRoutes()
    }

    func setTarget(_ target: OutputTarget, for app: AudioApp) {
        setTarget(target, forKey: app.id, name: app.name)
    }

    func setVolume(_ volume: Double, for app: AudioApp) {
        setVolume(volume, forKey: app.id, name: app.name)
    }

    func setMuted(_ muted: Bool, for app: AudioApp) {
        setMuted(muted, forKey: app.id, name: app.name)
    }

    func resetRule(for appID: String) {
        resetRule(forKey: appID)
    }

    // Per-process-kind overrides (advanced mode).

    func hasOverride(_ group: ProcessGroup) -> Bool {
        ruleStore.rules[group.id] != nil
    }

    /// The rule a process kind follows: its own override, or the app's rule.
    func effectiveRule(for group: ProcessGroup) -> AppRule {
        ruleStore.rules[group.id] ?? ruleStore.rule(for: group.appID)
    }

    func override(_ group: ProcessGroup, name: String, _ change: (inout AppRule) -> Void) {
        let base = effectiveRule(for: group)
        ruleStore.update(group.id, name: name, keepPassthrough: true) { rule in
            if ruleStore.rules[group.id] == nil { rule = base }
            change(&rule)
        }
        applyRoutes()
    }

    /// Advanced mode: per-process-kind rules inside an app (FR-ROUTE-10).
    var advancedMode: Bool = UserDefaults.standard.bool(forKey: "routing.advanced") {
        didSet {
            UserDefaults.standard.set(advancedMode, forKey: "routing.advanced")
            applyRoutes()
        }
    }

    /// Apps worth showing: playing now, or with a custom rule.
    var visibleApps: [AudioApp] {
        apps.filter { app in
            app.isPlaying || ruleStore.rules[app.id] != nil
                || (advancedMode && app.processGroups.contains { ruleStore.rules[$0.id] != nil })
        }
        .sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Saved rules whose app (or process kind) is not running right now.
    var dormantRules: [(key: String, rule: AppRule)] {
        let live = Set(apps.flatMap { [$0.id] + $0.processGroups.map(\.id) })
        return ruleStore.rules
            .filter { !live.contains($0.key) }
            .map { (key: $0.key, rule: $0.value) }
            .sorted { ($0.rule.appName ?? $0.key).localizedStandardCompare($1.rule.appName ?? $1.key) == .orderedAscending }
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
    /// Consecutive polls without any signal per routed key while its processes claim to play.
    @ObservationIgnored private var silentPolls: [String: Int] = [:]
    @ObservationIgnored private var playingKeys: Set<String> = []

    private func poll() {
        var silent = false
        for key in Array(ruleStore.rules.keys) + [Self.allAudioRouteKey] {
            guard let peak = router.takePeak(for: key) else { continue }
            levels[key] = peak
            if playingKeys.contains(key), peak == 0 {
                silentPolls[key, default: 0] += 1
            } else {
                silentPolls[key] = 0
            }
            // ~10 s of digital silence from apps that claim to play.
            if silentPolls[key, default: 0] >= 20 { silent = true }
#if DEBUG
            if pollCount % 4 == 0 { DebugTrace.write("peak \(key) \(peak)") }
#endif
        }
        if silent != capturedSilenceSuspected { capturedSilenceSuspected = silent }
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
        // SideCast's own processes, including a receiver copy in the iOS Simulator, must never be
        // captured by the "all audio" tap, or its output would loop back into itself.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        let own = AudioProcessScanner.processes()
            .filter { $0.pid == ownPID || ($0.bundleID != nil && $0.bundleID == ownBundleID) }
            .map(\.objectID)
        if own != ownProcessObjects { ownProcessObjects = own }
        let scanned = AudioProcessScanner.scan()
        if scanned != apps { apps = scanned }
        let devices = OutputDeviceScanner.outputDevices()
        if devices != outputDevices { outputDevices = devices }
        let defaultUID = OutputDeviceScanner.defaultOutputDeviceUID()
        if defaultUID != defaultOutputUID { defaultOutputUID = defaultUID }
        applyRoutes()
    }

    /// Re-applies routing (used by the premium extension).
    func refreshRoutes() {
        router.invalidate()
        applyRoutes()
    }

    func markFreeLimit(_ peerID: UUID) {
        wantedReceivers.remove(peerID)
        lastErrors[peerID] = String(localized: "Only one device without SideCast Premium can be connected at a time.")
    }

    private func applyRoutes() {
        var units: [RouteUnit] = []
        var offline: Set<String> = []
        var playing: Set<String> = []
        var needsPremium: Set<String> = []
        let connected = Set(connectedReceivers.map(\.id))
        // Per-app rules are free on this Mac; sending one app to a receiver needs Premium on
        // that receiver.
        for app in apps where !app.processes.isEmpty {
            // Split the app's processes between the app rule and any per-kind rules.
            var buckets: [String: [AudioProcess]] = [:]
            for group in app.processGroups {
                let key = advancedMode && ruleStore.rules[group.id] != nil ? group.id : app.id
                buckets[key, default: []].append(contentsOf: group.processes)
            }
            for (key, processes) in buckets {
                let rule = ruleStore.rule(for: key)
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
                        offline.insert(key)
                    }
                case .receiver(let id):
                    if !connected.contains(id) {
                        target = .discard
                        offline.insert(key)
                    } else if isPremium(receiver: id) {
                        target = .receiver(id)
                    } else {
                        target = .discard
                        needsPremium.insert(key)
                    }
                }
                if !rule.muted, processes.contains(where: \.isRunningOutput) {
                    playing.insert(key)
                }
                units.append(RouteUnit(
                    key: key,
                    name: app.name,
                    processes: processes.map(\.objectID),
                    target: target,
                    gain: rule.muted ? 0 : Float(rule.volume)
                ))
            }
        }
        // Everything else (apps without their own setting) goes to the "all audio" target.
        let routed = units.flatMap(\.processes)
        if let unit = allAudioRouteUnit(connected: connected, excluding: routed, offline: &offline) {
            units.append(unit)
        }
        playingKeys = playing
        if offline != offlineApps { offlineApps = offline }
        if needsPremium != premiumRequired { premiumRequired = needsPremium }
        router.apply(units, defaultDeviceUID: defaultOutputUID)
        let message = router.lastError.map { _ in String(localized: "SideCast could not capture app audio. Check the permission in System Settings.") }
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
            readySince[peer.id] = Date()
            // Give the receiver a moment to report its premium status before applying the
            // limit of one unpaid device.
            DispatchQueue.main.asyncAfter(deadline: .now() + PremiumTiming.statusGracePeriod + 0.1) { [weak self] in
                self?.enforceDeviceLimit()
            }
            applyRoutes()
        case .closed(let error):
            sessions.removeAll { $0 === session }
            if let peerID = session.peer?.id, !sessions.contains(where: { $0.peer?.id == peerID && $0.state == .ready }) {
                receiverPremium.removeValue(forKey: peerID)
                premiumStatusReceived.remove(peerID)
                readySince.removeValue(forKey: peerID)
                premiumChanged()
            }
            if let peerID = session.peer?.id, !sessions.contains(where: { $0.peer?.id == peerID && $0.state == .ready }) {
                streams.removeValue(forKey: peerID)?.stop()
                audioPorts.removeValue(forKey: peerID)
                router.invalidate()
            }
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
        case .receiverInfo(let port):
            guard let peerID = session.peer?.id else { return }
            audioPorts[peerID] = port
            restartStream(for: peerID)
        case .premiumStatus(let unlocked):
            guard let peerID = session.peer?.id else { return }
            premiumStatusReceived.insert(peerID)
            receiverPremium[peerID] = unlocked
            premiumChanged()
        default:
            Log.net.debug("Unhandled message \(String(describing: message), privacy: .public)")
        }
    }

    // MARK: - Network audio

    func audioMode(for receiverID: UUID) -> AudioMode {
        audioModes[receiverID] ?? .lowLatency
    }

    func setAudioMode(_ mode: AudioMode, for receiverID: UUID) {
        audioModes[receiverID] = mode
        if let data = try? JSONEncoder().encode(audioModes.reduce(into: [String: AudioMode]()) { $0[$1.key.uuidString] = $1.value }) {
            UserDefaults.standard.set(data, forKey: "audio.modes")
        }
        restartStream(for: receiverID)
    }

    private static func loadAudioModes() -> [UUID: AudioMode] {
        guard let data = UserDefaults.standard.data(forKey: "audio.modes"),
              let stored = try? JSONDecoder().decode([String: AudioMode].self, from: data) else { return [:] }
        return stored.reduce(into: [:]) { result, entry in
            if let id = UUID(uuidString: entry.key) { result[id] = entry.value }
        }
    }

    /// (Re)creates the UDP stream to a connected receiver with its current mode.
    private func restartStream(for receiverID: UUID) {
        guard let session = sessions.first(where: { $0.peer?.id == receiverID && $0.state == .ready }),
              let port = audioPorts[receiverID],
              let key = session.audioKey,
              let connection = (session.transport as? NWTransport)?.connection,
              case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint else { return }

        if let old = streams.removeValue(forKey: receiverID) {
            old.stop()
            session.send(.stopStream(streamID: old.config.streamID))
        }
        let codec = audioMode(for: receiverID).codec
        nextStreamID &+= 1
        let config = StreamConfig(
            streamID: nextStreamID,
            codec: codec,
            sampleRate: AudioWireFormat.sampleRate,
            channels: AudioWireFormat.channels,
            framesPerPacket: AudioWireFormat.framesPerPacket(for: codec)
        )
        do {
            let stream = try RemoteAudioStream(
                config: config,
                key: key,
                host: host,
                port: port,
                interface: connection.currentPath?.availableInterfaces.first
            )
            session.send(.startStream(config))
            stream.start()
            streams[receiverID] = stream
            Log.audio.info("Streaming to \(session.peer?.name ?? "?", privacy: .public) as \(codec.rawValue, privacy: .public) on port \(port)")
            DebugTrace.write("stream \(config.streamID) to \(host):\(port) codec=\(codec)")
        } catch {
            Log.audio.error("Could not start stream: \(String(describing: error), privacy: .public)")
        }
        router.invalidate()
        applyRoutes()
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
