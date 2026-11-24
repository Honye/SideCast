//
//  TouchInputView.swift
//  SideCast
//
//  Touch control on iPad / iPhone / Vision Pro (FR-TOUCH-01~04): one finger taps and drags,
//  two fingers scroll, a two-finger tap is a right click. Positions are sent as fractions of the
//  mirrored picture; touches on the black bars are ignored.
//

#if !os(macOS)
import SwiftUI
import UIKit

struct TouchInputView: UIViewRepresentable {
    let pictureSize: CGSize
    let send: (PointerEvent.Kind, CGPoint, CGSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.accessibilityIdentifier = "touch-control"
        let coordinator = context.coordinator
        coordinator.view = view

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap(_:)))
        let twoFingerTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.twoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        let drag = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.drag(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        // A two-finger tap that moves a little is still a tap, not a scroll.
        scroll.require(toFail: twoFingerTap)
        for recognizer in [tap, twoFingerTap, drag, scroll] {
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.pictureSize = pictureSize
        context.coordinator.send = send
    }

    final class Coordinator: NSObject {
        weak var view: UIView?
        var pictureSize = CGSize.zero
        var send: (PointerEvent.Kind, CGPoint, CGSize) -> Void = { _, _, _ in }
        private var dragging = false
        private var lastScrollTranslation = CGPoint.zero

        private var bounds: CGSize { view?.bounds.size ?? .zero }

        private func normalized(_ point: CGPoint) -> CGPoint? {
            PictureGeometry.normalized(point, picture: pictureSize, in: bounds)
        }

        private func clamped(_ point: CGPoint) -> CGPoint {
            PictureGeometry.clampedNormalized(point, picture: pictureSize, in: bounds)
        }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let point = normalized(recognizer.location(in: view)) else { return }
            send(.click, point, .zero)
        }

        @objc func twoFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let point = normalized(recognizer.location(in: view)) else { return }
            send(.rightClick, point, .zero)
        }

        @objc func drag(_ recognizer: UIPanGestureRecognizer) {
            let location = recognizer.location(in: view)
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

        @objc func scroll(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                lastScrollTranslation = .zero
                fallthrough
            case .changed:
                let translation = recognizer.translation(in: view)
                let delta = CGSize(width: translation.x - lastScrollTranslation.x, height: translation.y - lastScrollTranslation.y)
                lastScrollTranslation = translation
                let location = clamped(recognizer.location(in: view))
                send(.scroll, location, PictureGeometry.normalizedDelta(delta, picture: pictureSize, in: bounds))
            default:
                break
            }
        }
    }
}
#endif
