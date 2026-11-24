//
//  SenderController+Links.swift
//  SideCast
//
//  Wired first (FR-CONN-03/04): when a receiver becomes reachable over a better link (an iPad
//  plugged in by USB, a Thunderbolt Bridge), the Mac opens a second connection over it; once
//  that one is ready the old one is closed as "Replaced" and the audio / video streams move.
//  When the current link stops working (cable pulled), it switches back right away instead of
//  waiting for the connection to time out. A short pause while switching is fine (confirmed).
//

#if os(macOS)
import Foundation
import os

extension SenderController {
    /// Don't retry a switch for a receiver more often than this.
    static let linkSwitchCooldown: TimeInterval = 5

    func refreshLinks() {
        var updated: [UUID: LinkKind] = [:]
        for session in sessions where session.state == .ready {
            guard let id = session.peer?.id, self.session(for: id) === session else { continue }
            updated[id] = session.linkKind
        }
        if updated != links {
            links = updated
        }
    }

    func switchToBetterLinks() {
        for session in sessions where session.state == .ready {
            guard let id = session.peer?.id,
                  self.session(for: id) === session,
                  let peer = receivers.first(where: { $0.id == id }) else { continue }
            let current = session.linkKind
            let best = node.bestLink(to: peer)
            guard LinkKind.shouldSwitch(current: current, currentIsViable: session.linkIsViable, best: best) else { continue }
            // One attempt at a time per receiver.
            let switching = sessions.contains { !$0.state.isClosed && $0.state != .ready && $0.expectedPeerID == id }
            if switching { continue }
            if let last = linkSwitchAttempts[id], Date().timeIntervalSince(last) < Self.linkSwitchCooldown { continue }
            linkSwitchAttempts[id] = Date()
            Log.net.info("Switching \(peer.device.name, privacy: .public) from \(String(describing: current), privacy: .public) to \(String(describing: best), privacy: .public)")
            DebugTrace.write("link switch \(peer.device.name): \(current) -> \(best)")
            openSession(to: peer)
        }
    }

    /// A newer session for a receiver that was mirroring: move the video to it.
    func restartMirroringOnNewSession(_ receiverID: UUID) {
        if mirrorSessions[receiverID] != nil || pendingMirrors[receiverID] != nil {
            restartMirror(receiverID)
        } else {
            resumeMirroring(receiverID)
        }
    }
}
#endif
