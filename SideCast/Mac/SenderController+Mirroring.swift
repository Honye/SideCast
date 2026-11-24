//
//  SenderController+Mirroring.swift
//  SideCast
//
//  Screen mirroring (FR-SCREEN-01/04~07), as confirmed:
//  - Any connected receiver can be mirrored to, with or without Premium.
//  - Mirroring to several receivers at once needs Premium on each of them (FR-SCREEN-05).
//  - Mirroring starts on the Mac; the receiver can stop it.
//  - The pointer is shown.
//

#if os(macOS)
import CoreGraphics
import Foundation
import os

extension SenderController {
    func mirroredDisplay(for receiverID: UUID) -> CGDirectDisplayID? {
        mirroredDisplays[receiverID]
    }

    /// Starts (or switches) mirroring `display` to a connected receiver.
    func startMirroring(_ receiverID: UUID, display: CGDirectDisplayID) {
        let others = mirroredDisplays.keys.filter { id in id != receiverID && connectedReceivers.contains { $0.id == id } }
        guard MirrorPolicy.allows(
            candidateHasPremium: isPremium(receiver: receiverID),
            othersHavePremium: others.map { isPremium(receiver: $0) }
        ) else {
            onUpgradeNeeded?(.mirrorToSeveral)
            return
        }
        screenError = nil
        if mirroredDisplays[receiverID] != nil {
            endMirrorStream(receiverID, notifyReceiver: true)
        }
        mirroredDisplays[receiverID] = display
        requestMirror(receiverID)
    }

    func stopMirroring(_ receiverID: UUID, notifyReceiver: Bool = true) {
        mirroredDisplays.removeValue(forKey: receiverID)
        endMirrorStream(receiverID, notifyReceiver: notifyReceiver)
    }

    func stopAllMirroring() {
        for id in Array(mirroredDisplays.keys) {
            stopMirroring(id)
        }
    }

    /// After a (re)connection: continue mirroring if the user still wants it.
    func resumeMirroring(_ receiverID: UUID) {
        guard mirroredDisplays[receiverID] != nil, mirrorSessions[receiverID] == nil else { return }
        requestMirror(receiverID)
    }

    /// Starts the stream again, e.g. on a new connection after a link switch.
    func restartMirror(_ receiverID: UUID) {
        guard mirroredDisplays[receiverID] != nil else { return }
        endMirrorStream(receiverID, notifyReceiver: false)
        requestMirror(receiverID)
    }

    /// The connection dropped: the stream is gone; keep the wish only if we'll reconnect.
    func mirrorConnectionLost(_ receiverID: UUID, willReconnect: Bool) {
        endMirrorStream(receiverID, notifyReceiver: false)
        if !willReconnect {
            mirroredDisplays.removeValue(forKey: receiverID)
        }
    }

    /// Premium can change while mirroring (a refund, or a status that arrived late).
    func enforceMirrorPolicy() {
        let active = mirroredDisplays.keys.filter { id in connectedReceivers.contains { $0.id == id } }
        guard active.count > 1 else { return }
        for id in active where premiumStatusReceived.contains(id) && !isPremium(receiver: id) {
            stopMirroring(id)
            onUpgradeNeeded?(.mirrorToSeveral)
        }
    }

    func mirrorReady(_ ready: MirrorReady, from receiverID: UUID, session: PeerSession) {
        guard pendingMirrors[receiverID] == ready.streamID,
              let display = mirroredDisplays[receiverID],
              let key = session.videoKey,
              let (host, interface) = streamEndpoint(of: session) else { return }
        pendingMirrors.removeValue(forKey: receiverID)
        do {
            let mirror = try MirrorSession(
                receiverID: receiverID,
                displayID: display,
                ready: ready,
                key: key,
                host: host,
                interface: interface
            )
            mirror.onEnd = { [weak self] error in
                self?.mirrorEnded(receiverID, streamID: ready.streamID, error: error)
            }
            mirrorSessions[receiverID] = mirror
            Task {
                do {
                    try await mirror.start()
                    DebugTrace.write("mirror \(ready.streamID) to \(host):\(ready.port) started")
                    sendRemoteInputStatus(to: receiverID, streamID: ready.streamID)
                } catch {
                    mirrorEnded(receiverID, streamID: ready.streamID, error: error)
                }
            }
        } catch {
            mirrorEnded(receiverID, streamID: ready.streamID, error: error)
        }
    }

    // MARK: - Private

    private func requestMirror(_ receiverID: UUID) {
        guard let display = mirroredDisplays[receiverID],
              let session = sessions.first(where: { $0.peer?.id == receiverID && $0.state == .ready }) else { return }
        nextMirrorStreamID &+= 1
        let request = MirrorRequest(streamID: nextMirrorStreamID, displayName: MirrorDisplays.name(of: display))
        pendingMirrors[receiverID] = request.streamID
        session.send(.startMirroring(request))
    }

    private func endMirrorStream(_ receiverID: UUID, notifyReceiver: Bool) {
        let streamID = mirrorSessions[receiverID]?.streamID ?? pendingMirrors[receiverID]
        endRemoteInput(receiverID, display: mirrorSessions[receiverID]?.displayID)
        mirrorSessions.removeValue(forKey: receiverID)?.stop()
        pendingMirrors.removeValue(forKey: receiverID)
        if notifyReceiver, let streamID,
           let session = sessions.first(where: { $0.peer?.id == receiverID && $0.state == .ready }) {
            session.send(.stopMirroring(streamID: streamID))
        }
    }

    /// The stream stopped by itself: capture failed, permission missing, network gone.
    private func mirrorEnded(_ receiverID: UUID, streamID: UInt32, error: Error?) {
        guard mirrorSessions[receiverID]?.streamID == streamID || pendingMirrors[receiverID] == nil else { return }
        Log.audio.error("Mirroring ended: \(String(describing: error), privacy: .public)")
        if let error {
            screenError = Self.describeScreenError(error)
        }
        stopMirroring(receiverID)
    }

    private static func describeScreenError(_ error: Error) -> String {
        let nsError = error as NSError
        // ScreenCaptureKit: the user declined, or never allowed, screen recording.
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain", nsError.code == -3801 {
            return String(localized: "SideCast isn't allowed to record the screen.")
        }
        return error.localizedDescription
    }
}
#endif
