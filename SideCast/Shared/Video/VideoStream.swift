//
//  VideoStream.swift
//  SideCast
//
//  The encrypted TCP connection that carries a mirrored screen (see VideoWire.swift).
//

import CryptoKit
import Foundation
import Network
import os
import Synchronization

nonisolated enum VideoStreamParameters {
    static func tcp(interface: NWInterface? = nil) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVideo
        if let interface {
            parameters.requiredInterface = interface
        }
        return parameters
    }
}

/// Mac side: seals and sends video messages. `backlog` counts messages handed to the network
/// but not yet sent, so the caller can skip frames when the network falls behind.
nonisolated final class VideoStreamSender: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SideCast.video.send", qos: .userInteractive)
    private let connection: NWConnection
    private var sealer: FrameSealer
    private let pending = Atomic<Int>(0)
    private let failed = Atomic<Bool>(false)
    /// Called once on the main queue if the connection fails.
    var onFailure: (@MainActor () -> Void)?

    init(key: SymmetricKey, host: NWEndpoint.Host, port: UInt16, interface: NWInterface?) {
        sealer = FrameSealer(key: key)
        connection = NWConnection(
            host: host,
            port: NWEndpoint.Port(rawValue: port)!,
            using: VideoStreamParameters.tcp(interface: interface)
        )
    }

    var backlog: Int { pending.load(ordering: .relaxed) }
    var isFailed: Bool { failed.load(ordering: .relaxed) }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.fail()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        failed.store(true, ordering: .relaxed)
        connection.cancel()
    }

    /// Thread-safe.
    func send(_ message: VideoMessage) {
        guard !isFailed else { return }
        pending.add(1, ordering: .relaxed)
        queue.async { [self] in
            guard let sealed = try? sealer.seal(message.encoded()) else {
                pending.subtract(1, ordering: .relaxed)
                return
            }
            var length = UInt32(sealed.count).bigEndian
            let wire = Data(bytes: &length, count: 4) + sealed
            connection.send(content: wire, completion: .contentProcessed { [weak self] error in
                self?.pending.subtract(1, ordering: .relaxed)
                if error != nil { self?.fail() }
            })
        }
    }

    private func fail() {
        guard !failed.exchange(true, ordering: .relaxed) else { return }
        connection.cancel()
        DispatchQueue.main.async { [onFailure] in onFailure?() }
    }
}

/// Receiver side: listens for the Mac's video connection, opens and parses messages. Only the
/// newest connection is kept.
nonisolated final class VideoStreamReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SideCast.video.receive", qos: .userInteractive)
    private let key: SymmetricKey
    private var listener: NWListener?
    private var connection: NWConnection?
    private var opener: FrameOpener
    /// Called on the receive queue for every message.
    private let onMessage: @Sendable (VideoMessage) -> Void
    private(set) var messagesReceived = 0

    init(key: SymmetricKey, onMessage: @escaping @Sendable (VideoMessage) -> Void) {
        self.key = key
        self.opener = FrameOpener(key: key)
        self.onMessage = onMessage
    }

    /// Starts listening; `onReady` gets the TCP port on the main queue.
    func start(onReady: @escaping @Sendable (UInt16) -> Void) throws {
        let listener = try NWListener(using: VideoStreamParameters.tcp())
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connection?.cancel()
            self.connection = connection
            self.opener = FrameOpener(key: self.key)
            connection.start(queue: self.queue)
            self.readLength(on: connection)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue {
                DispatchQueue.main.async { onReady(port) }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            connection?.cancel()
            connection = nil
        }
    }

    private func readLength(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self, let data, data.count == 4, error == nil else {
                if isComplete || error != nil { connection.cancel() }
                return
            }
            let length = data.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= VideoMessage.maxWireLength else {
                Log.net.error("Video frame of \(length) bytes rejected")
                connection.cancel()
                return
            }
            self.readBody(length, on: connection)
        }
    }

    private func readBody(_ length: Int, on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, let data, data.count == length, error == nil else {
                connection.cancel()
                return
            }
            guard connection === self.connection,
                  let plaintext = try? self.opener.open(data),
                  let message = VideoMessage(plaintext) else {
                // Wrong key, replay or garbage: drop this connection.
                connection.cancel()
                return
            }
            self.messagesReceived += 1
            self.onMessage(message)
            self.readLength(on: connection)
        }
    }
}
