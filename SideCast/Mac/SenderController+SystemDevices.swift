//
//  SenderController+SystemDevices.swift
//  SideCast
//
//  Connected receivers as macOS output devices (website version, PRD 3.2): any app, or macOS
//  itself, can play to them. Each one appears while its receiver is connected; its volume
//  scales what SideCast sends to that receiver. Unpaid receivers can be used too.
//

#if os(macOS)
import CoreAudio
import Foundation
import os

extension SenderController {
    nonisolated static func systemDeviceRouteKey(_ receiver: UUID) -> String {
        "system-device:\(receiver.uuidString)"
    }

    /// Tells the driver which devices to show. Called on every route update, which also keeps
    /// the devices alive.
    func publishSystemDevices() {
        guard Self.publishesSystemDevices else { return }
        systemDriver.publish(connectedReceivers.map {
            SystemAudioDriver.Entry(uid: SystemAudioDriver.uid(for: $0.id), name: SystemAudioDriver.deviceName(for: $0.name))
        })
    }

    /// Looks up the receivers' devices and volumes, and puts a reconnected receiver back as the
    /// sound output if it was before.
    func refreshSystemDevices(previousDefault: String?) {
        var present: [UUID: AudioObjectID] = [:]
        if systemDriver.isInstalled {
            for receiver in connectedReceivers {
                if let device = systemDriver.device(for: receiver.id) {
                    present[receiver.id] = device
                }
            }
        }
        systemDevices = present
        observeVolume(of: Set(present.values))
        let gains = present.mapValues { systemDriver.gain(of: $0) }
        if gains != systemDeviceGains {
            DebugTrace.write("system device gains \(gains.map { "\($0.key.uuidString.prefix(8))=\($0.value)" })")
            systemDeviceGains = gains
        }

        var memory = systemOutputMemory
        let restore = memory.update(previousDefault: previousDefault, currentDefault: defaultOutputUID, presentReceivers: Set(present.keys))
        if memory != systemOutputMemory {
            systemOutputMemory = memory
            saveSystemOutputMemory()
        }
        if let restore, let device = present[restore] {
            DebugTrace.write("restoring \(restore) as default output")
            setDefaultOutput(device)
        }
    }

    /// Captures what is played to each receiver's output device, except apps SideCast already
    /// routes itself.
    func systemDeviceRouteUnits(connected: Set<UUID>, excluding routed: [AudioObjectID]) -> [RouteUnit] {
        let excluded = Array(Set(ownProcessObjects + routed)).sorted()
        return systemDevices.keys
            .filter { connected.contains($0) }
            .sorted { $0.uuidString < $1.uuidString }
            .map { receiver in
                RouteUnit(
                    key: Self.systemDeviceRouteKey(receiver),
                    name: connectedReceivers.first { $0.id == receiver }?.name ?? "Receiver",
                    processes: excluded,
                    target: .receiver(receiver),
                    gain: 1,
                    capturesAllExcept: true,
                    deviceUID: SystemAudioDriver.uid(for: receiver)
                )
            }
    }

    /// The output device's volume applies to everything SideCast sends to that receiver.
    func applyingSystemDeviceGain(_ unit: RouteUnit) -> RouteUnit {
        guard case .receiver(let id) = unit.target, let gain = systemDeviceGains[id], gain < 1 else { return unit }
        var scaled = RouteUnit(key: unit.key, name: unit.name, processes: unit.processes, target: unit.target, gain: unit.gain * gain)
        scaled.capturesAllExcept = unit.capturesAllExcept
        scaled.deviceUID = unit.deviceUID
        return scaled
    }

    /// Removes the devices right away when SideCast stops, and remembers a receiver that was
    /// the sound output so it can be put back next time.
    func stopSystemDevices() {
        if let receiver = SystemAudioDriver.receiver(forUID: defaultOutputUID) {
            systemOutputMemory = SystemOutputMemory(receiver: receiver, fallbackUID: nil)
            saveSystemOutputMemory()
        }
        if Self.publishesSystemDevices {
            systemDriver.publish([])
        }
    }

    /// Test profiles share the driver with the main copy of SideCast and leave it alone,
    /// unless a debug build is started with SIDECAST_SYSTEM_DEVICES=1.
    static var publishesSystemDevices: Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["SIDECAST_SYSTEM_DEVICES"] == "1" { return true }
#endif
        return RuntimeEnvironment.profile == nil
    }

    // MARK: - Helpers

    private func observeVolume(of devices: Set<AudioObjectID>) {
        for (device, block) in volumeListeners where !devices.contains(device) {
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                var address = CAProperty.address(selector, scope: kAudioObjectPropertyScopeOutput)
                AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
            }
            volumeListeners.removeValue(forKey: device)
        }
        for device in devices where volumeListeners[device] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleAudioRefresh() }
            }
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                var address = CAProperty.address(selector, scope: kAudioObjectPropertyScopeOutput)
                AudioObjectAddPropertyListenerBlock(device, &address, .main, block)
            }
            volumeListeners[device] = block
        }
    }

    private func setDefaultOutput(_ device: AudioObjectID) {
        var device = device
        var address = CAProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device
        )
        if status != noErr {
            Log.audio.error("Could not set the default output: \(status)")
        }
    }

    private static var systemOutputMemoryKey: String { RuntimeEnvironment.profiled("systemDevices.outputMemory") }

    static func loadSystemOutputMemory() -> SystemOutputMemory {
        guard let data = UserDefaults.standard.data(forKey: systemOutputMemoryKey),
              let memory = try? JSONDecoder().decode(SystemOutputMemory.self, from: data) else { return SystemOutputMemory() }
        return memory
    }

    private func saveSystemOutputMemory() {
        if let data = try? JSONEncoder().encode(systemOutputMemory) {
            UserDefaults.standard.set(data, forKey: Self.systemOutputMemoryKey)
        }
    }
}
#endif
