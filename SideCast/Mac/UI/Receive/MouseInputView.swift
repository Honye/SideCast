//
//  MouseInputView.swift
//  SideCast
//
//  Receive mode: the mouse in the mirror window controls the other Mac (confirmed, FR-TOUCH):
//  clicks, drags, right clicks, scrolling and pointer movement over the picture.
//

#if os(macOS)
import AppKit
import SwiftUI

struct MouseInputView: NSViewRepresentable {
    let pictureSize: CGSize
    let send: (PointerEvent.Kind, CGPoint, CGSize, PointerEvent.DeltaUnit) -> Void

    func makeNSView(context: Context) -> MouseInputNSView {
        MouseInputNSView()
    }

    func updateNSView(_ view: MouseInputNSView, context: Context) {
        view.pictureSize = pictureSize
        view.send = send
    }
}

final class MouseInputNSView: NSView {
    var pictureSize = CGSize.zero
    var send: (PointerEvent.Kind, CGPoint, CGSize, PointerEvent.DeltaUnit) -> Void = { _, _, _, _ in }
    private var pressed = false
    private var lastHover: TimeInterval = 0

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = PictureGeometry.normalized(location(event), picture: pictureSize, in: bounds.size) else { return }
        pressed = true
        send(.down, point, .zero, .picture)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed else { return }
        send(.move, PictureGeometry.clampedNormalized(location(event), picture: pictureSize, in: bounds.size), .zero, .picture)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        send(.up, PictureGeometry.clampedNormalized(location(event), picture: pictureSize, in: bounds.size), .zero, .picture)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let point = PictureGeometry.normalized(location(event), picture: pictureSize, in: bounds.size) else { return }
        send(.rightClick, point, .zero, .picture)
    }

    override func mouseMoved(with event: NSEvent) {
        // About 60 updates a second is plenty for the pointer.
        guard event.timestamp - lastHover >= 1.0 / 60,
              let point = PictureGeometry.normalized(location(event), picture: pictureSize, in: bounds.size) else { return }
        lastHover = event.timestamp
        send(.move, point, .zero, .picture)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = PictureGeometry.normalized(location(event), picture: pictureSize, in: bounds.size) else { return }
        // Scroll the other Mac as far as this one would: trackpads report points, mouse wheels
        // report lines.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let delta = CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale)
        guard delta != .zero else { return }
        send(.scroll, point, delta, .points)
    }
}
#endif
