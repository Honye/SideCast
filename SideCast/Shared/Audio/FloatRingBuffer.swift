//
//  FloatRingBuffer.swift
//  SideCast
//
//  Lock-free single-producer / single-consumer ring of Float samples, safe to use from a
//  real-time audio thread.
//

import Foundation
import Synchronization

nonisolated final class FloatRingBuffer: @unchecked Sendable {
    let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeCount = Atomic<Int>(0)
    private let readCount = Atomic<Int>(0)

    /// - Parameter capacity: rounded up to a power of two.
    init(capacity: Int) {
        var size = 1
        while size < capacity { size <<= 1 }
        self.capacity = size
        mask = size - 1
        storage = UnsafeMutablePointer<Float>.allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
    }

    deinit {
        storage.deallocate()
    }

    /// Samples ready to read.
    var available: Int {
        writeCount.load(ordering: .acquiring) - readCount.load(ordering: .acquiring)
    }

    // MARK: Producer

    /// Writes as many samples as fit; returns the number written.
    @discardableResult
    func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
        let written = writeCount.load(ordering: .relaxed)
        let read = readCount.load(ordering: .acquiring)
        let n = min(count, capacity - (written - read))
        guard n > 0 else { return 0 }
        for index in 0..<n {
            storage[(written + index) & mask] = source[index]
        }
        writeCount.store(written + n, ordering: .releasing)
        return n
    }

    @discardableResult
    func writeSilence(count: Int) -> Int {
        let written = writeCount.load(ordering: .relaxed)
        let read = readCount.load(ordering: .acquiring)
        let n = min(count, capacity - (written - read))
        guard n > 0 else { return 0 }
        for index in 0..<n {
            storage[(written + index) & mask] = 0
        }
        writeCount.store(written + n, ordering: .releasing)
        return n
    }

    // MARK: Consumer

    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let read = readCount.load(ordering: .relaxed)
        let written = writeCount.load(ordering: .acquiring)
        let n = min(count, written - read)
        guard n > 0 else { return 0 }
        for index in 0..<n {
            destination[index] = storage[(read + index) & mask]
        }
        readCount.store(read + n, ordering: .releasing)
        return n
    }

    /// Drops up to `count` samples.
    @discardableResult
    func skip(_ count: Int) -> Int {
        let read = readCount.load(ordering: .relaxed)
        let written = writeCount.load(ordering: .acquiring)
        let n = min(count, written - read)
        guard n > 0 else { return 0 }
        readCount.store(read + n, ordering: .releasing)
        return n
    }
}
