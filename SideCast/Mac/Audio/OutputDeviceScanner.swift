//
//  OutputDeviceScanner.swift
//  SideCast
//

#if os(macOS)
import CoreAudio
import Foundation

struct OutputDevice: Identifiable, Hashable {
    /// Core Audio device UID; stable across launches.
    let id: String
    let name: String
    let objectID: AudioObjectID
}

enum OutputDeviceScanner {
    static func outputDevices() -> [OutputDevice] {
        let ids = (try? CAProperty.array(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDevices,
            of: AudioObjectID.self
        )) ?? []
        return ids.compactMap { id in
            let outputChannels = (try? CAProperty.bufferChannelCounts(id, scope: kAudioObjectPropertyScopeOutput))?.reduce(0, +) ?? 0
            guard outputChannels > 0,
                  let uid = try? CAProperty.string(id, kAudioDevicePropertyDeviceUID),
                  let name = try? CAProperty.string(id, kAudioObjectPropertyName) else { return nil }
            return OutputDevice(id: uid, name: name, objectID: id)
        }
    }

    static func defaultOutputDeviceUID() -> String? {
        guard let id = try? CAProperty.value(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice,
            initial: AudioObjectID(kAudioObjectUnknown)
        ), id != kAudioObjectUnknown else { return nil }
        return try? CAProperty.string(id, kAudioDevicePropertyDeviceUID)
    }
}
#endif
