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

/// A screen mirroring stream the Mac wants to start (FR-SCREEN-01).
nonisolated struct MirrorRequest: Codable, Hashable, Sendable {
    var streamID: UInt32
    /// Name of the Mac display being mirrored, for the receiver's UI.
    var displayName: String
    /// The receiver is an extended display of its own rather than a copy (FR-SCREEN-02).
    var extended = false

    init(streamID: UInt32, displayName: String, extended: Bool = false) {
        self.streamID = streamID
        self.displayName = displayName
        self.extended = extended
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streamID = try container.decode(UInt32.self, forKey: .streamID)
        displayName = try container.decode(String.self, forKey: .displayName)
        extended = try container.decodeIfPresent(Bool.self, forKey: .extended) ?? false
    }
}

/// The receiver's answer: where to send the video and the largest picture worth sending.
nonisolated struct MirrorReady: Codable, Hashable, Sendable {
    var streamID: UInt32
    /// TCP port the receiver listens on for this stream.
    var port: UInt16
    /// The receiver's screen in pixels, landscape (width ≥ height).
    var maxWidth: Int
    var maxHeight: Int
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
    /// Mac → receiver: start showing a mirrored screen. The receiver answers `mirrorReady`.
    case startMirroring(MirrorRequest)
    case mirrorReady(MirrorReady)
    /// Either side: the stream ended. From the receiver it means the user stopped mirroring.
    case stopMirroring(streamID: UInt32)
    /// Receiver → Mac: the mirrored screen is (not) on screen, e.g. the app went to the
    /// background (FR-SCREEN-07). The Mac pauses sending while hidden.
    case mirrorVisibility(streamID: UInt32, visible: Bool)
    /// Receiver → Mac: the decoder lost track; send a key frame.
    case requestKeyframe(streamID: UInt32)
    /// Receiver → Mac: a touch (or mouse) action on the mirrored picture (FR-TOUCH).
    case pointer(PointerEvent)
    /// Mac → receiver: whether the Mac can act on `pointer` events for this stream.
    case remoteInputStatus(streamID: UInt32, status: RemoteInputStatus)
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
