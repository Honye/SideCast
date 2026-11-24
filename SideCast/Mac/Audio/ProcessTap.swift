//
//  ProcessTap.swift
//  SideCast
//
//  A Core Audio process tap: captures the audio of a set of processes and mutes their normal
//  output while SideCast reads the tap. If SideCast quits or crashes the tap goes away and the
//  apps play normally again.
//

#if os(macOS)
import CoreAudio
import Foundation

final class ProcessTap {
    let objectID: AudioObjectID
    let uid: String
    private(set) var processes: [AudioObjectID]
    private let description: CATapDescription

    /// Taps the given processes.
    convenience init(name: String, processes: [AudioObjectID]) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        try self.init(description: description, name: name, processes: processes)
    }

    /// Taps every process except the given ones (used to send all of the Mac's audio somewhere).
    convenience init(name: String, excluding processes: [AudioObjectID]) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
        try self.init(description: description, name: name, processes: processes)
    }

    /// Taps what every process except the given ones plays to one device (a SideCast output
    /// device from the audio driver).
    convenience init(name: String, excluding processes: [AudioObjectID], deviceUID: String) throws {
        let description = CATapDescription(excludingProcesses: processes, deviceUID: deviceUID, stream: 0)
        try self.init(description: description, name: name, processes: processes)
    }

    private init(description: CATapDescription, name: String, processes: [AudioObjectID]) throws {
        description.uuid = UUID()
        description.name = name
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        var objectID = AudioObjectID(kAudioObjectUnknown)
        try CAProperty.check(AudioHardwareCreateProcessTap(description, &objectID), "create process tap")
        self.description = description
        self.objectID = objectID
        self.uid = description.uuid.uuidString
        self.processes = processes
    }

    deinit {
        AudioHardwareDestroyProcessTap(objectID)
    }

    /// Changes the tapped processes without recreating the tap.
    func update(processes: [AudioObjectID]) throws {
        guard processes != self.processes else { return }
        description.processes = processes
        var address = CAProperty.address(kAudioTapPropertyDescription)
        var reference = description
        let status = withUnsafeMutablePointer(to: &reference) { pointer in
            AudioObjectSetPropertyData(objectID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), pointer)
        }
        try CAProperty.check(status, "update process tap")
        self.processes = processes
    }

    func format() throws -> AudioStreamBasicDescription {
        try CAProperty.value(objectID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
    }
}
#endif
