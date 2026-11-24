//
//  SystemAudioDriver.swift
//  SideCast
//
//  Talks to the SideCast audio driver (website version only, PRD 3.2): tells it which connected
//  receivers to show as macOS output devices, reads their volume, and installs or removes it.
//  See Driver/Source/SideCastAudioDriver.h for the driver side.
//

#if os(macOS)
import AppKit
import CoreAudio
import Foundation
import Observation
import os

@Observable
final class SystemAudioDriver {
    struct Entry: Equatable {
        let uid: String
        let name: String
    }

    static let bundleID = "com.imarkr.SideCast.AudioDriver"
    nonisolated static let uidPrefix = "com.imarkr.SideCast.receiver."
    static let devicesSelector = SystemAudioDriver.selector("scdv")
    static let versionSelector = SystemAudioDriver.selector("scvr")
    /// Only the website version can install and use the driver (PRD 3.2).
    static var isSupported: Bool { RuntimeEnvironment.distribution == .website }
    /// The driver drops devices it hasn't heard about for 10 s; refresh well before that.
    static let heartbeat: TimeInterval = 2
    /// The volume control's floor; anything at or below it is silence.
    static let minDecibels: Float = -96

    /// Version of the installed driver, or nil if it isn't installed (or Core Audio hasn't
    /// loaded it yet).
    private(set) var installedVersion: Int?
    /// Version of the driver inside this app.
    let bundledVersion: Int? = SystemAudioDriver.readBundledVersion()
    /// The installer or uninstaller was opened and Core Audio hasn't changed yet.
    private(set) var waitingForInstaller = false

    var isInstalled: Bool { installedVersion != nil }
    var updateAvailable: Bool {
        guard let installedVersion, let bundledVersion else { return false }
        return bundledVersion > installedVersion
    }

    @ObservationIgnored private var plugin = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var published: [Entry]?
    @ObservationIgnored private var lastPush = Date.distantPast
    @ObservationIgnored private var pluginListener: AudioObjectPropertyListenerBlock?

    init() {
        refreshPlugin()
    }

    /// Watches for the driver being installed or removed.
    func startMonitoring(onChange: @escaping () -> Void) {
        guard Self.isSupported, pluginListener == nil else { return }
        var address = CAProperty.address(kAudioHardwarePropertyPlugInList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refreshPlugin()
                onChange()
            }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        pluginListener = block
    }

    /// Asks Core Audio again whether the driver is loaded (e.g. after it restarted).
    func refreshPlugin() {
        guard Self.isSupported else { return }
        var bundleID = Self.bundleID as CFString
        var address = CAProperty.address(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
        var found = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &bundleID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifier, &size, &found
            )
        }
        let pluginID = status == noErr ? found : AudioObjectID(kAudioObjectUnknown)
        let version = pluginID == kAudioObjectUnknown
            ? nil
            : (try? CAProperty.string(pluginID, Self.versionSelector)).flatMap { Int($0) }
        if pluginID != plugin {
            plugin = pluginID
            published = nil
        }
        if version != installedVersion {
            installedVersion = version
            waitingForInstaller = false
            Log.audio.info("Audio driver: \(version.map(String.init) ?? "not installed", privacy: .public)")
        }
    }

    // MARK: - Devices

    static func uid(for receiver: UUID) -> String {
        uidPrefix + receiver.uuidString
    }

    /// The receiver a SideCast output device stands for, if `uid` is one.
    nonisolated static func receiver(forUID uid: String?) -> UUID? {
        guard let uid, uid.hasPrefix(uidPrefix) else { return nil }
        return UUID(uuidString: String(uid.dropFirst(uidPrefix.count)))
    }

    static func deviceName(for receiverName: String) -> String {
        "\(receiverName) (SideCast)"
    }

    /// Shows exactly these devices. Call it regularly: the driver removes devices that aren't
    /// refreshed, so they go away if SideCast quits unexpectedly.
    func publish(_ entries: [Entry]) {
        guard plugin != kAudioObjectUnknown else { return }
        guard entries != published || Date().timeIntervalSince(lastPush) >= Self.heartbeat else { return }
        let list = entries.map { ["uid": $0.uid, "name": $0.name] } as CFArray
        var value: CFPropertyList = list
        var address = CAProperty.address(Self.devicesSelector)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(plugin, &address, 0, nil, UInt32(MemoryLayout<CFPropertyList>.size), pointer)
        }
        lastPush = Date()
        if status == noErr {
            if entries != published {
                DebugTrace.write("driver devices \(entries.map(\.name))")
            }
            published = entries
        } else {
            Log.audio.error("Could not publish devices to the audio driver: \(status)")
        }
    }

    /// The Core Audio device standing for a receiver, if the driver shows it right now.
    func device(for receiver: UUID) -> AudioObjectID? {
        var uid = Self.uid(for: receiver) as CFString
        var address = CAProperty.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device
            )
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// The gain set with the device's volume and mute (volume keys, Control Center).
    func gain(of device: AudioObjectID) -> Float {
        let output = kAudioObjectPropertyScopeOutput
        let muted = (try? CAProperty.value(device, kAudioDevicePropertyMute, scope: output, initial: UInt32(0))) ?? 0
        guard muted == 0 else { return 0 }
        guard let decibels = try? CAProperty.value(device, kAudioDevicePropertyVolumeDecibels, scope: output, initial: Float32(0)) else {
            return 1
        }
        return Self.gain(decibels: decibels)
    }

    static func gain(decibels: Float) -> Float {
        guard decibels > minDecibels else { return 0 }
        return min(1, powf(10, decibels / 20))
    }

    // MARK: - Install / uninstall

    static var installerPackage: URL? {
        Bundle.main.url(forResource: "SideCast Audio Driver", withExtension: "pkg")
    }

    static var uninstallerPackage: URL? {
        Bundle.main.url(forResource: "Uninstall SideCast Audio Driver", withExtension: "pkg")
    }

    /// Opens the installer; macOS asks for an administrator password.
    func install() {
        open(Self.installerPackage)
    }

    func uninstall() {
        open(Self.uninstallerPackage)
    }

    private func open(_ package: URL?) {
        guard Self.isSupported, let package else { return }
        waitingForInstaller = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let installer = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.installer") {
            NSWorkspace.shared.open([package], withApplicationAt: installer, configuration: configuration) { _, error in
                guard let error else { return }
                Log.audio.error("Could not open the installer: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { self.waitingForInstaller = false }
            }
        } else {
            NSWorkspace.shared.open(package)
        }
    }

    // MARK: - Helpers

    private static func readBundledVersion() -> Int? {
        guard let url = Bundle.main.url(forResource: "SideCastAudio", withExtension: "driver"),
              let version = Bundle(url: url)?.object(forInfoDictionaryKey: "SideCastDriverVersion") as? String else { return nil }
        return Int(version)
    }

    private static func selector(_ code: String) -> AudioObjectPropertySelector {
        code.utf8.reduce(0) { $0 << 8 | AudioObjectPropertySelector($1) }
    }
}

/// Puts a receiver back as macOS's sound output when it reconnects, if it was the output when
/// it went away and the user hasn't picked another device since.
nonisolated struct SystemOutputMemory: Codable, Equatable {
    /// The receiver whose device was the output when it disappeared.
    var receiver: UUID?
    /// What macOS switched to then; nil if not seen yet (e.g. SideCast quit meanwhile).
    var fallbackUID: String?

    /// Updates the memory after the default output or the set of SideCast devices changed.
    /// Returns a receiver whose device should become the default output again.
    mutating func update(previousDefault: String?, currentDefault: String?, presentReceivers: Set<UUID>) -> UUID? {
        if SystemAudioDriver.receiver(forUID: currentDefault) != nil {
            self = SystemOutputMemory()
            return nil
        }
        if let previous = SystemAudioDriver.receiver(forUID: previousDefault), currentDefault != previousDefault {
            if presentReceivers.contains(previous) {
                // The user chose another output.
                self = SystemOutputMemory()
            } else {
                self = SystemOutputMemory(receiver: previous, fallbackUID: currentDefault)
            }
            return nil
        }
        guard let receiver else { return nil }
        if fallbackUID == nil {
            fallbackUID = currentDefault
        } else if fallbackUID != currentDefault {
            // The user picked something else meanwhile.
            self = SystemOutputMemory()
            return nil
        }
        guard presentReceivers.contains(receiver) else { return nil }
        self = SystemOutputMemory()
        return receiver
    }
}
#endif
