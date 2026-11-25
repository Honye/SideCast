//
//  TouchInputView.swift
//  SideCast
//
//  Touch control on iPad / iPhone / Vision Pro. Two modes:
//  - Trackpad (FR-TOUCH-07, the default): one finger slides anywhere to move the Mac's pointer,
//    a tap clicks where the pointer is, a long press then slide drags, two fingers scroll and a
//    two-finger tap is a right click. The finger never hides the pointer.
//  - Direct (FR-TOUCH-01~04): the pointer goes where the finger is. One finger taps and drags,
//    two fingers scroll, a two-finger tap is a right click. Positions are sent as fractions of
//    the mirrored picture; touches on the black bars are ignored.
//

#if !os(macOS)
import SwiftUI
import UIKit

struct TouchInputView: UIViewRepresentable {
    let pictureSize: CGSize
    let mode: TouchControlMode
    /// Direct mode: an action at a point in the picture.
    let send: (PointerEvent.Kind, CGPoint, CGSize) -> Void
    /// Trackpad mode: an action where the pointer is, with a movement or scroll distance.
    let sendTrackpad: (PointerEvent.Kind, CGSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.accessibilityIdentifier = "touch-control"
        context.coordinator.view = view
        context.coordinator.install(mode)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.pictureSize = pictureSize
        coordinator.send = send
        coordinator.sendTrackpad = sendTrackpad
        coordinator.install(mode)
    }

    final class Coordinator: NSObject {
        weak var view: UIView?
        var pictureSize = CGSize.zero
        var send: (PointerEvent.Kind, CGPoint, CGSize) -> Void = { _, _, _ in }
        var sendTrackpad: (PointerEvent.Kind, CGSize) -> Void = { _, _ in }
        private var mode: TouchControlMode?
        private var dragging = false
        private var lastScrollTranslation = CGPoint.zero
        private var lastPressLocation = CGPoint.zero

        private var bounds: CGSize { view?.bounds.size ?? .zero }

        /// Sets up the gestures for `mode` (again, if it changed).
        func install(_ mode: TouchControlMode) {
            guard let view, mode != self.mode else { return }
            self.mode = mode
            if dragging {
                dragging = false
                switch mode {
                case .trackpad: send(.up, PictureGeometry.clampedNormalized(lastPressLocation, picture: pictureSize, in: bounds), .zero)
                case .direct: sendTrackpad(.up, .zero)
                }
            }
            view.gestureRecognizers?.forEach(view.removeGestureRecognizer)

            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTap(_:)))
            twoFingerTap.numberOfTouchesRequired = 2
            let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
            scroll.minimumNumberOfTouches = 2
            scroll.maximumNumberOfTouches = 2
            // A two-finger tap that moves a little is still a tap, not a scroll.
            scroll.require(toFail: twoFingerTap)
            var recognizers: [UIGestureRecognizer] = [twoFingerTap, scroll]

            switch mode {
            case .direct:
                let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
                let drag = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
                drag.minimumNumberOfTouches = 1
                drag.maximumNumberOfTouches = 1
                recognizers += [tap, drag]
            case .trackpad:
                let tap = UITapGestureRecognizer(target: self, action: #selector(trackpadTap(_:)))
                let press = UILongPressGestureRecognizer(target: self, action: #selector(trackpadPress(_:)))
                press.minimumPressDuration = 0.4
                press.allowableMovement = 10
                let move = UIPanGestureRecognizer(target: self, action: #selector(trackpadMove(_:)))
                move.minimumNumberOfTouches = 1
                move.maximumNumberOfTouches = 1
                // Holding still first grabs (drag); sliding right away only moves the pointer.
                move.require(toFail: press)
                recognizers += [tap, press, move]
            }
            recognizers.forEach(view.addGestureRecognizer)
        }

        private func normalized(_ point: CGPoint) -> CGPoint? {
            PictureGeometry.normalized(point, picture: pictureSize, in: bounds)
        }

        private func clamped(_ point: CGPoint) -> CGPoint {
            PictureGeometry.clampedNormalized(point, picture: pictureSize, in: bounds)
        }

        // MARK: Both modes

        @objc func twoFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            if mode == .trackpad {
                sendTrackpad(.rightClick, .zero)
            } else if let point = normalized(recognizer.location(in: view)) {
                send(.rightClick, point, .zero)
            }
        }

        @objc func scroll(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                lastScrollTranslation = .zero
                fallthrough
            case .changed:
                let translation = recognizer.translation(in: view)
                let delta = CGSize(width: translation.x - lastScrollTranslation.x, height: translation.y - lastScrollTranslation.y)
                lastScrollTranslation = translation
                let distance = PictureGeometry.normalizedDelta(delta, picture: pictureSize, in: bounds)
                if mode == .trackpad {
                    sendTrackpad(.scroll, distance)
                } else {
                    send(.scroll, clamped(recognizer.location(in: view)), distance)
                }
            default:
                break
            }
        }

        // MARK: Direct

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let point = normalized(recognizer.location(in: view)) else { return }
            send(.click, point, .zero)
        }

        @objc func drag(_ recognizer: UIPanGestureRecognizer) {
            let location = recognizer.location(in: view)
            lastPressLocation = location
            switch recognizer.state {
            case .began:
                // The press happened where the finger first touched, before it moved enough
                // to count as a drag.
                let translation = recognizer.translation(in: view)
                let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
                guard let point = normalized(start) else { return }
                dragging = true
                send(.down, point, .zero)
                send(.move, clamped(location), .zero)
            case .changed:
                guard dragging else { return }
                send(.move, clamped(location), .zero)
            case .ended, .cancelled, .failed:
                guard dragging else { return }
                dragging = false
                send(.up, clamped(location), .zero)
            default:
                break
            }
        }

        // MARK: Trackpad

        @objc func trackpadTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            sendTrackpad(.click, .zero)
        }

        @objc func trackpadMove(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                let translation = recognizer.translation(in: view)
                recognizer.setTranslation(.zero, in: view)
                movePointer(by: translation, velocity: recognizer.velocity(in: view))
            default:
                break
            }
        }

        /// Long press, then slide: drag with the left button held.
        @objc func trackpadPress(_ recognizer: UILongPressGestureRecognizer) {
            let location = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                dragging = true
                lastPressLocation = location
#if os(iOS)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
#endif
                sendTrackpad(.down, .zero)
            case .changed:
                guard dragging else { return }
                let translation = CGPoint(x: location.x - lastPressLocation.x, y: location.y - lastPressLocation.y)
                lastPressLocation = location
                // Long presses don't report a velocity; drags stay precise at 1:1.
                movePointer(by: translation, velocity: .zero)
            case .ended, .cancelled, .failed:
                guard dragging else { return }
                dragging = false
                sendTrackpad(.up, .zero)
            default:
                break
            }
        }

        private func movePointer(by translation: CGPoint, velocity: CGPoint) {
            guard translation != .zero else { return }
            let delta = TrackpadMotion.pictureDelta(
                viewDelta: CGSize(width: translation.x, height: translation.y),
                velocity: velocity, picture: pictureSize, in: bounds
            )
            sendTrackpad(.move, delta)
        }
    }
}
#endif
