//
//  PeerSessionError+Message.swift
//  SideCast
//

import Foundation

extension PeerSessionError {
    var userMessage: String {
        switch self {
        case .pairingFailed:
            String(localized: "The pairing code was incorrect.")
        case .pairingExpired:
            String(localized: "The pairing code expired. Try again to get a new code.")
        case let .peerBusy(name):
            String(localized: "This device is in use by \(name).")
        case .roleMismatch:
            String(localized: "Both devices are in the same mode.")
        case .authenticationFailed:
            String(localized: "The device could not be verified.")
        case .transportClosed:
            String(localized: "The connection was lost.")
        case .protocolViolation:
            String(localized: "The connection failed.")
        }
    }

    /// Errors after which reconnecting automatically makes no sense.
    var isFinal: Bool {
        switch self {
        case .pairingFailed, .pairingExpired, .peerBusy, .roleMismatch, .authenticationFailed:
            true
        case .transportClosed, .protocolViolation:
            false
        }
    }
}

/// Connection status of one remote device, for display.
enum LinkStatus: Equatable {
    case available
    case connecting
    case pairing
    case connected
    case failed(String)
}

extension PeerSession.State {
    var linkStatus: LinkStatus {
        switch self {
        case .connecting, .handshaking: .connecting
        case .pairingShowCode, .pairingEnterCode, .pairingVerifying: .pairing
        case .ready: .connected
        case .closed(let error): error.map { .failed($0.userMessage) } ?? .available
        }
    }
}
