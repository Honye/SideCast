//
//  NowPlayingController.swift
//  SideCast
//
//  Lock screen / Control Center card while connected (FR-RECV-04): shows the connected Mac,
//  the system volume slider, and a pause button that disconnects.
//

#if !os(macOS)
import Foundation
import MediaPlayer

final class NowPlayingController {
    var onDisconnect: (() -> Void)?
    private var targets: [(MPRemoteCommand, Any)] = []

    func show(macName: String) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "SideCast",
            MPMediaItemPropertyArtist: String(localized: "Connected to \(macName)"),
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        for command in [center.pauseCommand, center.togglePlayPauseCommand, center.stopCommand] {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                MainActor.assumeIsolated { self?.onDisconnect?() }
                return .success
            }
            targets.append((command, target))
        }
        for command in [center.playCommand, center.nextTrackCommand, center.previousTrackCommand,
                        center.skipForwardCommand, center.skipBackwardCommand, center.changePlaybackPositionCommand] {
            command.isEnabled = false
        }
    }

    func hide() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        for (command, target) in targets {
            command.removeTarget(target)
        }
        targets = []
    }
}
#endif
