//
//  LinkKind.swift
//  SideCast
//
//  What a connection runs over, and which is preferred (FR-CONN-03/04): wired (USB to an
//  iPad / iPhone, Thunderbolt Bridge between Macs, Ethernet) > Wi-Fi network > peer-to-peer
//  Wi-Fi. USB uses the network link macOS and iOS bring up over the cable, through the public
//  Network framework (as confirmed; no usbmuxd).
//

import Foundation
import Network

nonisolated enum LinkKind: Int, Comparable, Sendable, CaseIterable {
    case unknown = 0
    case peerToPeer = 1
    case wifi = 2
    case wired = 3
    /// The same machine (side-by-side debug instances).
    case local = 4

    static func < (lhs: LinkKind, rhs: LinkKind) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Classifies an interface by name and type.
    /// - `anpi*`: the Mac's network link to an iPad / iPhone on a USB cable.
    /// - `bridge*`: Thunderbolt Bridge between two Macs.
    /// - `awdl*`, `llw*`: Apple peer-to-peer Wi-Fi.
    static func classify(name: String, type: NWInterface.InterfaceType) -> LinkKind {
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { return .peerToPeer }
        if name.hasPrefix("anpi") || name.hasPrefix("bridge") { return .wired }
        switch type {
        case .loopback: return .local
        case .wiredEthernet: return .wired
        case .wifi: return .wifi
        default: return .unknown
        }
    }

    static func of(_ interface: NWInterface) -> LinkKind {
        classify(name: interface.name, type: interface.type)
    }

    /// Whether to open a new connection to a device (FR-CONN-04): the current one stopped
    /// working (e.g. its cable was pulled) while the device is still reachable, or a wired link
    /// came up and the current one isn't wired. Only wired links can be forced, so other
    /// "better" links never cause a switch (and never a loop, e.g. over a VPN tunnel).
    static func shouldSwitch(current: LinkKind, currentIsViable: Bool, best: LinkKind) -> Bool {
        if !currentIsViable { return best != .unknown }
        return best == .wired && current < .wired
    }

    /// The link a connection's path uses, if it has one.
    static func of(_ path: NWPath?) -> LinkKind {
        guard let path, path.status == .satisfied, let interface = path.availableInterfaces.first else { return .unknown }
        return of(interface)
    }
}
