//
//  HandshakeCrypto.swift
//  SideCast
//
//  Key agreement, authentication and pairing proofs used by the SideCast handshake.
//
//  Handshake outline:
//  1. Both sides exchange a plaintext `Hello` (device info, long-term Ed25519 identity key,
//     ephemeral X25519 key).
//  2. Session keys are derived with HKDF from the X25519 shared secret, salted with a hash of
//     both hellos (the transcript).
//  3. Each side proves possession of its identity key by signing the transcript.
//  4. If either side does not yet trust the other, the Mac shows a 6 digit code that the user
//     types on the receiver. Both sides prove knowledge of the code with an HMAC bound to the
//     transcript, then store each other's identity key as trusted.
//

import CryptoKit
import Foundation

nonisolated struct SessionKeys: Sendable {
    /// Key for frames this side sends on the control channel.
    let send: SymmetricKey
    /// Key for frames this side receives on the control channel.
    let receive: SymmetricKey
    /// Key for audio packets (sender → receiver).
    let audio: SymmetricKey
    /// Key for the screen mirroring stream (sender → receiver).
    let video: SymmetricKey
}

nonisolated enum HandshakeCrypto {
    static let protocolLabel = "SideCast handshake v1"
    static let pairingCodeLength = 6

    static func transcript(initiatorHello: Data, responderHello: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(protocolLabel.utf8))
        hasher.update(data: lengthPrefixed(initiatorHello))
        hasher.update(data: lengthPrefixed(responderHello))
        return Data(hasher.finalize())
    }

    static func deriveKeys(
        local: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Data,
        transcript: Data,
        isInitiator: Bool
    ) throws -> SessionKeys {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let secret = try local.sharedSecretFromKeyAgreement(with: peer)
        func key(_ label: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: transcript,
                sharedInfo: Data(label.utf8),
                outputByteCount: 32
            )
        }
        let initiatorToResponder = key("control initiator->responder")
        let responderToInitiator = key("control responder->initiator")
        let audio = key("audio sender->receiver")
        let video = key("video sender->receiver")
        return isInitiator
            ? SessionKeys(send: initiatorToResponder, receive: responderToInitiator, audio: audio, video: video)
            : SessionKeys(send: responderToInitiator, receive: initiatorToResponder, audio: audio, video: video)
    }

    /// The bytes a device signs with its identity key to authenticate itself.
    static func authPayload(transcript: Data, signer: DeviceRole) -> Data {
        Data("SideCast auth \(signer.rawValue)".utf8) + transcript
    }

    /// Proof that `prover` knows the pairing code, bound to this handshake.
    static func pairingProof(code: String, transcript: Data, prover: DeviceRole) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("SideCast pairing \(prover.rawValue)".utf8),
            using: pairingKey(code: code, transcript: transcript)
        )
        return Data(mac)
    }

    static func isValidPairingProof(_ proof: Data, code: String, transcript: Data, prover: DeviceRole) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: Data("SideCast pairing \(prover.rawValue)".utf8),
            using: pairingKey(code: code, transcript: transcript)
        )
    }

    static func generatePairingCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<pairingCodeLength).map { _ in String(Int.random(in: 0...9, using: &generator)) }.joined()
    }

    private static func pairingKey(code: String, transcript: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
            salt: transcript,
            info: Data("SideCast pairing key".utf8),
            outputByteCount: 32
        )
    }

    private static func lengthPrefixed(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        return Data(bytes: &length, count: 4) + data
    }
}
