//
//  DeviceInfo.swift
//  SideCast
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

nonisolated enum DevicePlatform: String, Codable, Sendable, CaseIterable {
    case mac, iPad, iPhone, vision

    var symbolName: String {
        switch self {
        case .mac: "laptopcomputer"
        case .iPad: "ipad"
        case .iPhone: "iphone"
        case .vision: "vision.pro"
        }
    }
}

/// Whether a device is sending audio (Mac) or playing it (iPad, iPhone, Vision Pro, Mac in receive mode).
nonisolated enum DeviceRole: String, Codable, Sendable {
    case sender, receiver
}

nonisolated struct DeviceInfo: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var platform: DevicePlatform
    var role: DeviceRole
}

extension DevicePlatform {
    /// The platform this app is running on.
    static var current: DevicePlatform {
#if os(macOS)
        .mac
#elseif os(visionOS)
        .vision
#else
        UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
#endif
    }
}

enum DeviceName {
    /// A human readable name for this device.
    static var current: String {
#if os(macOS)
        Host.current().localizedName ?? "Mac"
#else
        UIDevice.current.name
#endif
    }
}
