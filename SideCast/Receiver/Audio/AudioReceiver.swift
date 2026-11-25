//
//  AudioReceiver.swift
//  SideCast
//
//  Receives encrypted audio datagrams from the Mac, decodes them and feeds the jitter buffer.
//

import CryptoKit
import Foundation
import Network
import os

nonisolated final class AudioReceiver: @unchecked Sendable {
    let ring: FloatRingBuffer

    private let key: SymmetricKey
    private let queue = DispatchQueue(label: "SideCast.receive", qos: .userInteractive)
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var config: StreamConfig?
    private var decoder: AudioPacketDecoder?
    private var reorder = PacketReorderBuffer<Data>(maxHeld: 4)
    private var decodeBuffer = [Float](repeating: 0, count: 4_096)
    private(set) var packetsReceived = 0
    private(set) var packetsLost = 0

    init(key: SymmetricKey, ring: FloatRingBuffer) {
        self.key = key
        self.ring = ring
    }

    /// Starts listening; `onReady` gets the UDP port on the main queue.
    func start(onReady: @escaping @Sendable (UInt16) -> Void) throws {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(on: connection)
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
            connections.forEach { $0.cancel() }
            connections = []
        }
    }

    /// Switches to a new stream (or none).
    func setStream(_ config: StreamConfig?) {
        queue.async { [self] in
            self.config = config
            reorder = PacketReorderBuffer(maxHeld: config.map { PacketReorderBuffer<Data>.maxHeld(framesPerPacket: $0.framesPerPacket) } ?? 4)
            decoder = config.flatMap { try? makeDecoder(for: $0.codec) }
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data {
                self.handle(data)
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ datagram: Data) {
        guard let config, decoder != nil,
              let (header, payload) = try? AudioPacket.open(datagram, key: key),
              header.streamID == config.streamID, header.codec == config.codec else { return }
        packetsReceived += 1
        // Packets that arrive a little out of order are put back in order (test report,
        // 2026-11-25); only packets that never come are replaced with silence.
        for output in reorder.insert(sequence: header.sequence, payload: payload) {
            switch output {
            case .packet(let payload):
                play(payload)
            case .missing(let lost):
                // At most 100 ms of silence.
                packetsLost += lost
                ring.writeSilence(count: min(lost * config.framesPerPacket, 4_800) * 2)
            }
        }
    }

    private func play(_ payload: Data) {
        guard let decoder else { return }
        let frames = decodeBuffer.withUnsafeMutableBufferPointer { buffer in
            (try? decoder.decode(payload, into: buffer.baseAddress!, maxFrames: buffer.count / 2)) ?? 0
        }
        if frames > 0 {
            decodeBuffer.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: frames * 2) }
        }
    }
}
