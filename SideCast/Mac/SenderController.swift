//
//  SenderController.swift
//  SideCast
//
//  Top-level state for the Mac (sender) side.
//

#if os(macOS)
import Foundation
import Network
import Observation
import os

@Observable
final class SenderController {
    let identity: LocalIdentity
    let trustStore: TrustStore
    let node: NetworkNode

    /// Live and recently failed sessions.
    private(set) var sessions: [PeerSession] = []
    /// Last failure per receiver, shown until the next attempt.
    private(set) var lastErrors: [UUID: String] = [:]

    /// Receivers the user wants connected; reconnected automatically after a drop.
    @ObservationIgnored private var wantedReceivers: Set<UUID> = []
    @ObservationIgnored private var reconnectWork: [UUID: DispatchWorkItem] = [:]
    @ObservationIgnored private let pairingPanel = PairingPanelController()
    @ObservationIgnored private var started = false

    init() {
        identity = IdentityStore.loadOrCreate(role: .sender)
        trustStore = TrustStore()
        node = NetworkNode(identity: identity)
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
        Log.app.info("Sender started as \(self.identity.device.name, privacy: .public)")
    }

    func stop() {
        for session in sessions {
            session.close(reason: "Mac quit")
        }
        node.stop()
    }

    // MARK: - Queries

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

    // MARK: - Actions

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
        case .closed(let error):
            sessions.removeAll { $0 === session }
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
