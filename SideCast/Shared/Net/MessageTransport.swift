//
//  MessageTransport.swift
//  SideCast
//
//  A reliable, ordered, framed byte transport used by `PeerSession`.
//

import Foundation
import Network

protocol MessageTransport: AnyObject {
    var onReady: (() -> Void)? { get set }
    var onFrame: ((Data) -> Void)? { get set }
    var onClose: ((Error?) -> Void)? { get set }
    func start()
    func send(_ frame: Data)
    func close()
}

/// `MessageTransport` over an `NWConnection` (TCP). All callbacks run on the main queue.
final class NWTransport: MessageTransport {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onFrame: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private var decoder = FrameDecoder()
    private var finished = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    var remoteEndpoint: NWEndpoint? { connection.currentPath?.remoteEndpoint }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        connection.start(queue: .main)
    }

    func send(_ frame: Data) {
        guard !finished else { return }
        connection.send(content: Framing.encode(frame), completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated { self?.finish(error) }
        })
    }

    func close() {
        guard !finished else { return }
        finished = true
        connection.cancel()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            onReady?()
            receive()
        case .waiting(let error), .failed(let error):
            finish(error)
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                if let data, !data.isEmpty {
                    do {
                        for frame in try self.decoder.append(data) {
                            self.onFrame?(frame)
                            if self.finished { return }
                        }
                    } catch {
                        self.finish(error)
                        return
                    }
                }
                if let error {
                    self.finish(error)
                } else if isComplete {
                    self.finish(nil)
                } else {
                    self.receive()
                }
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        connection.cancel()
        onClose?(error)
    }
}

/// In-memory transport pair for tests. Frames are queued and delivered by `LoopbackLink.drain()`.
final class LoopbackLink {
    let a: LoopbackTransport
    let b: LoopbackTransport
    private var queue: [() -> Void] = []

    init() {
        a = LoopbackTransport()
        b = LoopbackTransport()
        a.link = self
        b.link = self
        a.peer = b
        b.peer = a
    }

    fileprivate func enqueue(_ work: @escaping () -> Void) {
        queue.append(work)
    }

    /// Delivers queued frames until none are left.
    func drain() {
        while !queue.isEmpty {
            queue.removeFirst()()
        }
    }
}

final class LoopbackTransport: MessageTransport {
    var onReady: (() -> Void)?
    var onFrame: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?
    fileprivate weak var link: LoopbackLink?
    fileprivate weak var peer: LoopbackTransport?
    private(set) var closed = false

    func start() {
        link?.enqueue { [weak self] in self?.onReady?() }
    }

    func send(_ frame: Data) {
        guard !closed else { return }
        link?.enqueue { [weak peer] in
            guard let peer, !peer.closed else { return }
            peer.onFrame?(frame)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        link?.enqueue { [weak peer] in
            guard let peer, !peer.closed else { return }
            peer.closed = true
            peer.onClose?(nil)
        }
    }
}
