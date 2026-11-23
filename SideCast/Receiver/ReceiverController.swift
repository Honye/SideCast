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

    private(set) var sessions: [PeerSession] = []
    private(set) var lastError: String?

    @ObservationIgnored private var started = false

    init() {
        identity = IdentityStore.loadOrCreate(role: .receiver)
        trustStore = TrustStore()
        node = NetworkNode(identity: identity)
    }

    func start() {
        guard !started, !RuntimeEnvironment.isRunningTests else { return }
        started = true
        node.onIncomingConnection = { [weak self] connection in
            self?.accept(connection)
        }
        node.start()
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
        case .closed(let error):
            sessions.removeAll { $0 === session }
            if let error, session.isInitiator || error.isFinal {
                lastError = error.userMessage
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
}
#endif
