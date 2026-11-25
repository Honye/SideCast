//
//  SenderController+Mirroring.swift
//  SideCast
//
//  Screen mirroring and extended display (FR-SCREEN-01/02/04~07), as confirmed:
//  - Any connected receiver can be mirrored to, with or without Premium.
//  - Showing the screen on several receivers at once needs Premium on each (FR-SCREEN-05).
//  - It starts on the Mac; the receiver can stop it.
//  - The pointer is shown.
//  - Extended display: website version only; a virtual display sized for the receiver.
//

#if os(macOS)
import CoreGraphics
import Foundation
import os

/// What a receiver shows of this Mac.
enum ScreenMode: Hashable {
    /// A copy of one of the Mac's displays.
    case mirror(CGDirectDisplayID)
    /// A display of its own that windows can be moved to.
    case extend
}

struct MirrorSetupError: LocalizedError {
    var errorDescription: String? { String(localized: "SideCast couldn't start showing the screen.") }
}

struct ExtendedDisplayError: LocalizedError {
    var errorDescription: String? { String(localized: "SideCast couldn't create the extended display.") }
}

extension SenderController {
    /// After a dropped connection, how long an extended display stays (with its windows) waiting
    /// for the receiver to come back.
    static let extendedDisplayGracePeriod: TimeInterval = 10

    func mirroredDisplay(for receiverID: UUID) -> CGDirectDisplayID? {
        if case .mirror(let display) = screenModes[receiverID] { return display }
        return nil
    }

    func isExtending(_ receiverID: UUID) -> Bool {
        screenModes[receiverID] == .extend
    }

    /// Starts (or switches) mirroring `display` to a connected receiver.
    func startMirroring(_ receiverID: UUID, display: CGDirectDisplayID) {
        start(receiverID, mode: .mirror(display))
    }

    /// Makes a connected receiver an extended display (FR-SCREEN-02).
    func startExtending(_ receiverID: UUID) {
        guard VirtualDisplay.isSupported else { return }
        start(receiverID, mode: .extend)
    }

    func stopMirroring(_ receiverID: UUID, notifyReceiver: Bool = true) {
        screenModes.removeValue(forKey: receiverID)
        endMirrorStream(receiverID, notifyReceiver: notifyReceiver)
        removeVirtualDisplay(receiverID)
    }

    func stopAllMirroring() {
        for id in Array(screenModes.keys) {
            stopMirroring(id)
        }
    }

    /// After a (re)connection: continue if the user still wants it.
    func resumeMirroring(_ receiverID: UUID) {
        guard screenModes[receiverID] != nil, mirrorSessions[receiverID] == nil else { return }
        requestMirror(receiverID)
    }

    /// Starts the stream again, e.g. on a new connection after a link switch. An extended
    /// display stays, so its windows don't move.
    func restartMirror(_ receiverID: UUID) {
        guard screenModes[receiverID] != nil else { return }
        endMirrorStream(receiverID, notifyReceiver: false)
        requestMirror(receiverID)
    }

    /// The connection dropped: the stream is gone; keep the wish only if we'll reconnect.
    func mirrorConnectionLost(_ receiverID: UUID, willReconnect: Bool) {
        endMirrorStream(receiverID, notifyReceiver: false)
        if willReconnect {
            scheduleVirtualDisplayRemoval(receiverID)
        } else {
            screenModes.removeValue(forKey: receiverID)
            removeVirtualDisplay(receiverID)
        }
    }

    /// Premium can change while showing the screen (a refund, or a status that arrived late).
    func enforceMirrorPolicy() {
        let active = screenModes.keys.filter { id in connectedReceivers.contains { $0.id == id } }
        guard active.count > 1 else { return }
        for id in active where premiumStatusReceived.contains(id) && !isPremium(receiver: id) {
            stopMirroring(id)
            onUpgradeNeeded?(.mirrorToSeveral)
        }
    }

    func mirrorReady(_ ready: MirrorReady, from receiverID: UUID, session: PeerSession) {
        guard pendingMirrors[receiverID] == ready.streamID, let mode = screenModes[receiverID] else { return }
        switch mode {
        case .mirror(let display):
            startMirrorSession(ready, display: display, receiverID: receiverID, session: session)
        case .extend:
            cancelVirtualDisplayRemoval(receiverID)
            let pixels = CGSize(width: ready.maxWidth, height: ready.maxHeight)
            if let existing = virtualDisplays[receiverID], existing.receiverPixels == pixels {
                startMirrorSession(ready, display: existing.displayID, receiverID: receiverID, session: session)
                return
            }
            virtualDisplays.removeValue(forKey: receiverID)
            let name = connectedReceivers.first { $0.id == receiverID }?.name ?? "SideCast"
            guard let display = VirtualDisplay(name: "\(name) (SideCast)", receiver: receiverID, receiverPixels: pixels) else {
                mirrorEnded(receiverID, streamID: ready.streamID, error: ExtendedDisplayError())
                return
            }
            virtualDisplays[receiverID] = display
            Task {
                let online = await display.waitUntilOnline()
                guard pendingMirrors[receiverID] == ready.streamID, virtualDisplays[receiverID] === display else { return }
                guard online else {
                    mirrorEnded(receiverID, streamID: ready.streamID, error: ExtendedDisplayError())
                    return
                }
                startMirrorSession(ready, display: display.displayID, receiverID: receiverID, session: session)
            }
        }
    }

    // MARK: - Private

    private func start(_ receiverID: UUID, mode: ScreenMode) {
        let others = screenModes.keys.filter { id in id != receiverID && connectedReceivers.contains { $0.id == id } }
        guard MirrorPolicy.allows(
            candidateHasPremium: isPremium(receiver: receiverID),
            othersHavePremium: others.map { isPremium(receiver: $0) }
        ) else {
            onUpgradeNeeded?(.mirrorToSeveral)
            return
        }
        screenError = nil
        if screenModes[receiverID] != nil {
            endMirrorStream(receiverID, notifyReceiver: true)
        }
        if mode != .extend {
            removeVirtualDisplay(receiverID)
        }
        screenModes[receiverID] = mode
        requestMirror(receiverID)
    }

    /// Starts capturing and sending. The stream stays pending until the session exists, so a
    /// failure here still ends it properly: the receiver is told and the error shown.
    private func startMirrorSession(_ ready: MirrorReady, display: CGDirectDisplayID, receiverID: UUID, session: PeerSession) {
        guard let key = session.videoKey, let (host, interface) = streamEndpoint(of: session) else {
            mirrorEnded(receiverID, streamID: ready.streamID, error: MirrorSetupError())
            return
        }
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
            pendingMirrors.removeValue(forKey: receiverID)
            Task {
                do {
                    try await mirror.start()
                    DebugTrace.write("mirror \(ready.streamID) of display \(display) to \(host):\(ready.port) started")
                    sendRemoteInputStatus(to: receiverID, streamID: ready.streamID)
                } catch {
                    mirrorEnded(receiverID, streamID: ready.streamID, error: error)
                }
            }
        } catch {
            mirrorEnded(receiverID, streamID: ready.streamID, error: error)
        }
    }

    private func requestMirror(_ receiverID: UUID) {
        guard let mode = screenModes[receiverID],
              let session = sessions.first(where: { $0.peer?.id == receiverID && $0.state == .ready }) else { return }
        nextMirrorStreamID &+= 1
        let request: MirrorRequest
        switch mode {
        case .mirror(let display):
            request = MirrorRequest(streamID: nextMirrorStreamID, displayName: MirrorDisplays.name(of: display))
        case .extend:
            request = MirrorRequest(streamID: nextMirrorStreamID, displayName: "", extended: true)
        }
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
        guard mirrorSessions[receiverID]?.streamID == streamID || pendingMirrors[receiverID] == streamID else { return }
        Log.audio.error("Screen stream ended: \(String(describing: error), privacy: .public)")
        if let error {
            screenError = Self.describeScreenError(error)
        }
        stopMirroring(receiverID)
    }

    private func removeVirtualDisplay(_ receiverID: UUID) {
        cancelVirtualDisplayRemoval(receiverID)
        virtualDisplays.removeValue(forKey: receiverID)
    }

    private func scheduleVirtualDisplayRemoval(_ receiverID: UUID) {
        guard virtualDisplays[receiverID] != nil else { return }
        cancelVirtualDisplayRemoval(receiverID)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mirrorSessions[receiverID] == nil else { return }
            // The receiver didn't come back: give the windows back to the other displays.
            self.virtualDisplayRemovals.removeValue(forKey: receiverID)
            self.virtualDisplays.removeValue(forKey: receiverID)
        }
        virtualDisplayRemovals[receiverID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.extendedDisplayGracePeriod, execute: work)
    }

    private func cancelVirtualDisplayRemoval(_ receiverID: UUID) {
        virtualDisplayRemovals.removeValue(forKey: receiverID)?.cancel()
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
