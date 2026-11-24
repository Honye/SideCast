//
//  SenderController+RemoteInput.swift
//  SideCast
//
//  Touch control (FR-TOUCH), website version only: pointer events from a receiver that is
//  being mirrored to act on the mirrored display. The receiver turns it on or off (FR-TOUCH-05);
//  the Mac tells it whether it can act on them.
//

#if os(macOS)
import CoreGraphics
import Foundation

extension SenderController {
    func handlePointer(_ event: PointerEvent, from receiverID: UUID, session: PeerSession) {
        guard let mirror = mirrorSessions[receiverID], mirror.streamID == event.streamID else { return }
        let display = mirror.displayID
        let status = RemoteInputInjector.status
        switch status {
        case .available:
            let injector = inputInjectors[receiverID] ?? RemoteInputInjector()
            inputInjectors[receiverID] = injector
            injector.handle(event, display: display)
        case .needsPermission:
            // Ask when touch control is first used, not before.
            if !inputPermissionRequested {
                inputPermissionRequested = true
                RemoteInputInjector.requestPermission()
            }
            if !inputPermissionNeeded { inputPermissionNeeded = true }
            session.send(.remoteInputStatus(streamID: event.streamID, status: status))
        case .unsupported:
            session.send(.remoteInputStatus(streamID: event.streamID, status: status))
        }
    }

    /// Tells a receiver whether touch control works, when its mirror stream starts.
    func sendRemoteInputStatus(to receiverID: UUID, streamID: UInt32) {
        guard let session = sessions.first(where: { $0.peer?.id == receiverID && $0.state == .ready }) else { return }
        session.send(.remoteInputStatus(streamID: streamID, status: RemoteInputInjector.status))
    }

    /// Notices the permission being granted (or taken away) while mirroring.
    func refreshRemoteInputStatus() {
        guard !mirrorSessions.isEmpty else { return }
        let status = RemoteInputInjector.status
        guard status != lastRemoteInputStatus else { return }
        lastRemoteInputStatus = status
        if status == .available, inputPermissionNeeded { inputPermissionNeeded = false }
        for (receiverID, mirror) in mirrorSessions {
            sendRemoteInputStatus(to: receiverID, streamID: mirror.streamID)
        }
    }

    /// Mirroring to a receiver stopped: let go of anything it was holding.
    func endRemoteInput(_ receiverID: UUID, display: CGDirectDisplayID?) {
        guard let injector = inputInjectors.removeValue(forKey: receiverID) else { return }
        if let display { injector.release(display: display) }
    }
}
#endif
