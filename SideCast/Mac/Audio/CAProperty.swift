//
//  CAProperty.swift
//  SideCast
//
//  Small helpers for reading Core Audio object properties.
//

#if os(macOS)
import CoreAudio
import Foundation

nonisolated struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let operation: String

    var description: String { "\(operation) failed: \(status) (\(CAProperty.fourCC(UInt32(bitPattern: status))))" }
}

nonisolated enum CAProperty {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
        guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
    }

    static func value<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) throws -> T {
        var address = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        try check(status, "get \(fourCC(selector))")
        return value
    }

    static func array<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of type: T.Type
    ) throws -> [T] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "size \(fourCC(selector))")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw), "get \(fourCC(selector))")
        let typed = raw.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> String {
        var address = address(selector, scope: scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "get \(fourCC(selector))")
        return (value?.takeRetainedValue() as String?) ?? ""
    }

    /// Channel count of each buffer in a device's stream configuration.
    static func bufferChannelCounts(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [Int] {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "size stream configuration")
        guard size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw), "get stream configuration")
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(value)
    }
}
#endif
