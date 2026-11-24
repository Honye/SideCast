//
//  PeerSession.swift
//  SideCast
//
//  One authenticated, encrypted control connection between a Mac and a receiver.
//  See HandshakeCrypto.swift for the protocol outline.
//

import CryptoKit
import Foundation
import Observation
import os

enum PeerSessionError: Error, Equatable {
    case protocolViolation(String)
    case authenticationFailed
    case roleMismatch
    case pairingFailed
    case pairingExpired
    case peerBusy(String)
    /// The Mac is already connected to another receiver without Premium.
    case freeDeviceLimit
    case transportClosed
}

@Observable
final class PeerSession: Identifiable {
    enum State: Equatable {
        case connecting
        case handshaking
        /// Mac side: show this code and wait for the receiver.
        case pairingShowCode(String)
        /// Receiver side: ask the user for the code shown on the Mac.
        case pairingEnterCode
        /// Receiver side: code submitted, waiting for the Mac to confirm.
        case pairingVerifying
        case ready
        case closed(PeerSessionError?)

        var isClosed: Bool {
            if case .closed = self { return true }
            return false
        }
    }

    static let pairingCodeLifetime: TimeInterval = 120

    let id = UUID()
    let isInitiator: Bool
    private(set) var state: State = .connecting {
        didSet {
            guard oldValue != state else { return }
            DebugTrace.write("session \(peer?.name ?? "?") \(oldValue) -> \(state)")
            onStateChange?(state)
        }
    }
    private(set) var peer: DeviceInfo?
    /// For outgoing connections: the device we expect to reach. The handshake fails otherwise.
    var expectedPeerID: UUID?

    @ObservationIgnored var onStateChange: ((State) -> Void)?
    @ObservationIgnored var onMessage: ((ControlMessage) -> Void)?
    /// Receiver side: returns the name of the Mac that currently occupies this receiver, if any.
    @ObservationIgnored var busyCheck: ((DeviceInfo) -> String?)?
    /// Clock used for pairing code expiry. Replaceable in tests.
    @ObservationIgnored var now: () -> Date = Date.init

    @ObservationIgnored let transport: MessageTransport
    @ObservationIgnored private let identity: LocalIdentity
    @ObservationIgnored private let trustStore: TrustStore
    @ObservationIgnored private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    @ObservationIgnored private var localHello: Data?
    @ObservationIgnored private var transcript: Data?
    @ObservationIgnored private var sealer: FrameSealer?
    @ObservationIgnored private var opener: FrameOpener?
    @ObservationIgnored private var peerIdentityKey: Data?
    @ObservationIgnored private var localTrustsPeer = false
    @ObservationIgnored private var receivedAuth = false
    @ObservationIgnored private var pairingCode: String?
    @ObservationIgnored private var pairingCodeIssuedAt: Date?
    @ObservationIgnored private var enteredCode: String?
    @ObservationIgnored private(set) var audioKey: SymmetricKey?
    @ObservationIgnored private(set) var videoKey: SymmetricKey?

    private var role: DeviceRole { identity.device.role }

    init(identity: LocalIdentity, trustStore: TrustStore, transport: MessageTransport, isInitiator: Bool) {
        self.identity = identity
        self.trustStore = trustStore
        self.transport = transport
        self.isInitiator = isInitiator
    }

    func start() {
        transport.onReady = { [weak self] in self?.transportReady() }
        transport.onFrame = { [weak self] frame in self?.handleFrame(frame) }
        transport.onClose = { [weak self] _ in self?.transportClosed() }
        transport.start()
    }

    /// Receiver side: submit the code the user typed.
    func submitPairingCode(_ code: String) {
        guard state == .pairingEnterCode, let transcript else { return }
        enteredCode = code
        state = .pairingVerifying
        send(.pairingProof(HandshakeCrypto.pairingProof(code: code, transcript: transcript, prover: .receiver)))
    }

    func send(_ message: ControlMessage) {
        guard var sealer, !state.isClosed else { return }
        do {
            let frame = try sealer.seal(JSONEncoder().encode(message))
            self.sealer = sealer
            transport.send(frame)
        } catch {
            fail(.protocolViolation("encode: \(error)"))
        }
    }

    func close(reason: String = "closed") {
        guard !state.isClosed else { return }
        send(.goodbye(reason: reason))
        transport.close()
        state = .closed(nil)
    }

    // MARK: - Handshake

    private func transportReady() {
        guard state == .connecting else { return }
        state = .handshaking
        if isInitiator {
            sendHello()
        }
    }

    private func sendHello() {
        let hello = Hello(
            version: Hello.currentVersion,
            device: identity.device,
            identityKey: identity.publicKey,
            ephemeralKey: ephemeral.publicKey.rawRepresentation
        )
        let data = (try? JSONEncoder().encode(hello)) ?? Data()
        localHello = data
        transport.send(data)
    }

    private func handleFrame(_ frame: Data) {
        guard !state.isClosed else { return }
        do {
            if transcript == nil {
                try handleHello(frame)
            } else {
                guard var opener else { throw PeerSessionError.protocolViolation("no keys") }
                let plaintext = try opener.open(frame)
                self.opener = opener
                try handle(JSONDecoder().decode(ControlMessage.self, from: plaintext))
            }
        } catch let error as PeerSessionError {
            fail(error)
        } catch {
            fail(.protocolViolation(String(describing: error)))
        }
    }

    private func handleHello(_ data: Data) throws {
        let hello = try JSONDecoder().decode(Hello.self, from: data)
        guard hello.version == Hello.currentVersion else {
            throw PeerSessionError.protocolViolation("unsupported version \(hello.version)")
        }
        guard hello.device.role != role else { throw PeerSessionError.roleMismatch }
        guard hello.device.id != identity.device.id else { throw PeerSessionError.protocolViolation("connected to self") }
        if let expectedPeerID, expectedPeerID != hello.device.id {
            throw PeerSessionError.protocolViolation("unexpected peer")
        }

        if !isInitiator {
            sendHello()
        }
        guard let localHello else { throw PeerSessionError.protocolViolation("hello order") }
        let transcript = isInitiator
            ? HandshakeCrypto.transcript(initiatorHello: localHello, responderHello: data)
            : HandshakeCrypto.transcript(initiatorHello: data, responderHello: localHello)
        let keys = try HandshakeCrypto.deriveKeys(
            local: ephemeral,
            peerPublicKey: hello.ephemeralKey,
            transcript: transcript,
            isInitiator: isInitiator
        )
        self.transcript = transcript
        sealer = FrameSealer(key: keys.send)
        opener = FrameOpener(key: keys.receive)
        audioKey = keys.audio
        videoKey = keys.video
        peer = hello.device
        peerIdentityKey = hello.identityKey
        localTrustsPeer = trustStore.isTrusted(hello.device, identityKey: hello.identityKey)

        let signature = try identity.signingKey.signature(
            for: HandshakeCrypto.authPayload(transcript: transcript, signer: role)
        )
        send(.auth(signature: signature, trustsPeer: localTrustsPeer))
    }

    private func handle(_ message: ControlMessage) throws {
        switch message {
        case let .auth(signature, peerTrustsLocal):
            try handleAuth(signature: signature, peerTrustsLocal: peerTrustsLocal)

        case let .busy(occupiedBy):
            throw PeerSessionError.peerBusy(occupiedBy)

        case .pairingRequired:
            guard role == .receiver, receivedAuth, state == .handshaking else {
                throw PeerSessionError.protocolViolation("unexpected pairingRequired")
            }
            state = .pairingEnterCode

        case let .pairingProof(proof):
            try handlePairingProof(proof)

        case let .pairingResult(success, proof):
            guard role == .receiver, state == .pairingVerifying,
                  let code = enteredCode, let transcript, let peer, let peerIdentityKey else {
                throw PeerSessionError.protocolViolation("unexpected pairingResult")
            }
            guard success, let proof,
                  HandshakeCrypto.isValidPairingProof(proof, code: code, transcript: transcript, prover: .sender) else {
                throw PeerSessionError.pairingFailed
            }
            trustStore.trust(peer, identityKey: peerIdentityKey)
            state = .ready

        case let .goodbye(reason):
            transport.close()
            state = .closed(reason == GoodbyeReason.freeDeviceLimit ? .freeDeviceLimit : nil)

        default:
            guard state == .ready else {
                throw PeerSessionError.protocolViolation("message before ready")
            }
            onMessage?(message)
        }
    }

    private func handleAuth(signature: Data, peerTrustsLocal: Bool) throws {
        guard !receivedAuth, let transcript, let peer, let peerIdentityKey else {
            throw PeerSessionError.protocolViolation("unexpected auth")
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: peerIdentityKey)
        guard publicKey.isValidSignature(signature, for: HandshakeCrypto.authPayload(transcript: transcript, signer: peer.role)) else {
            throw PeerSessionError.authenticationFailed
        }
        receivedAuth = true

        if role == .receiver, let occupiedBy = busyCheck?(peer) {
            send(.busy(occupiedBy: occupiedBy))
            transport.close()
            state = .closed(nil)
            return
        }

        if localTrustsPeer && peerTrustsLocal {
            state = .ready
        } else if role == .sender {
            let code = HandshakeCrypto.generatePairingCode()
            pairingCode = code
            pairingCodeIssuedAt = now()
            state = .pairingShowCode(code)
            DebugTrace.write("pairing code for \(peer.name): \(code)")
            send(.pairingRequired)
        }
        // Receiver without mutual trust waits for `.pairingRequired`.
    }

    private func handlePairingProof(_ proof: Data) throws {
        guard role == .sender, case .pairingShowCode = state,
              let code = pairingCode, let issuedAt = pairingCodeIssuedAt,
              let transcript, let peer, let peerIdentityKey else {
            throw PeerSessionError.protocolViolation("unexpected pairingProof")
        }
        guard now().timeIntervalSince(issuedAt) <= Self.pairingCodeLifetime else {
            send(.pairingResult(success: false, proof: nil))
            throw PeerSessionError.pairingExpired
        }
        guard HandshakeCrypto.isValidPairingProof(proof, code: code, transcript: transcript, prover: .receiver) else {
            send(.pairingResult(success: false, proof: nil))
            throw PeerSessionError.pairingFailed
        }
        trustStore.trust(peer, identityKey: peerIdentityKey)
        send(.pairingResult(
            success: true,
            proof: HandshakeCrypto.pairingProof(code: code, transcript: transcript, prover: .sender)
        ))
        state = .ready
    }

    private func fail(_ error: PeerSessionError) {
        guard !state.isClosed else { return }
        Log.net.error("Session with \(self.peer?.name ?? "?", privacy: .public) failed: \(String(describing: error), privacy: .public)")
        transport.close()
        state = .closed(error)
    }

    private func transportClosed() {
        guard !state.isClosed else { return }
        state = .closed(.transportClosed)
    }
}

extension PeerSession {
    /// What this session's connection runs over (FR-CONN-03/04).
    var linkKind: LinkKind {
        (transport as? NWTransport)?.linkKind ?? .unknown
    }

    /// False while the connection can't send, e.g. right after its cable was pulled.
    var linkIsViable: Bool {
        (transport as? NWTransport)?.isViable ?? true
    }
}
