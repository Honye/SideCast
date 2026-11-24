//
//  LinkLabel.swift
//  SideCast
//
//  Shows what a connection runs over, e.g. "Wired" when an iPad is on a USB cable (FR-CONN-03).
//

import SwiftUI

struct LinkLabel: View {
    let link: LinkKind

    var body: some View {
        switch link {
        case .wired:
            Label("Wired", systemImage: "cable.connector")
        case .wifi:
            Label("Wi-Fi", systemImage: "wifi")
        case .peerToPeer:
            Label("Peer-to-peer Wi-Fi", systemImage: "antenna.radiowaves.left.and.right")
        case .local:
            Label("This device", systemImage: "desktopcomputer")
        case .unknown:
            EmptyView()
        }
    }
}
