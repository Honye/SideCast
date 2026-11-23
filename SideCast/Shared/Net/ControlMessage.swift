//
//  ControlMessage.swift
//  SideCast
//
//  Messages on the control channel.
//

import Foundation

/// First, plaintext message each side sends.
nonisolated struct Hello: Codable, Sendable {
    static let currentVersion = 1

    var version: Int
    var device: DeviceInfo
    var identityKey: Data
    var ephemeralKey: Data
}

nonisolated enum AudioCodecKind: String, Codable, Sendable {
    /// Uncompressed 24-bit PCM (high quality mode).
    case pcm24
    /// Opus (low latency mode).
    case opus
}

nonisolated struct StreamConfig: Codable, Hashable, Sendable {
    var streamID: UInt32
    var codec: AudioCodecKind
    var sampleRate: Double
    var channels: Int
    /// Audio frames carried by one packet.
    var framesPerPacket: Int
}

/// Encrypted messages exchanged after the hellos.
nonisolated enum ControlMessage: Codable, Sendable, Equatable {
    /// Identity proof: signature over the transcript, and whether the sender already trusts the peer.
    case auth(signature: Data, trustsPeer: Bool)
    /// The receiver is already connected to another Mac.
    case busy(occupiedBy: String)
    /// Sent by the Mac: a pairing code is shown, ask the user to type it.
    case pairingRequired
    case pairingProof(Data)
    case pairingResult(success: Bool, proof: Data?)
    /// Sent by the receiver once connected: the UDP port it listens on for audio.
    case receiverInfo(audioPort: UInt16)
    case startStream(StreamConfig)
    case stopStream(streamID: UInt32)
    /// Sent by a receiver: whether it bought SideCast Premium (FR-PAY-04).
    case premiumStatus(unlocked: Bool)
    case ping(id: UInt64)
    case pong(id: UInt64)
    case goodbye(reason: String)
}

/// Well-known `goodbye` reasons the receiver explains to the user.
nonisolated enum GoodbyeReason {
    /// The Mac is already connected to another receiver without Premium (FR-CONN-09).
    static let freeDeviceLimit = "free-device-limit"
}
