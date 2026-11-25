//
//  RemoteInput.swift
//  SideCast
//
//  Touch control (FR-TOUCH): a receiver's touches, or its mouse in Mac receive mode, become
//  mouse actions on the mirrored Mac display. Positions travel as fractions of the picture so
//  they don't depend on either screen's size.
//

import CoreGraphics
import Foundation

/// A pointer action on the mirrored picture.
nonisolated struct PointerEvent: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Press, move while pressed, release: a drag (FR-TOUCH-02). A move without a press
        /// only moves the pointer (Mac receivers' hover).
        case down, move, up
        /// Press and release in one go (FR-TOUCH-01).
        case click
        /// Right button click (FR-TOUCH-04).
        case rightClick
        /// Scroll by `dx` / `dy` (FR-TOUCH-03).
        case scroll
    }

    var streamID: UInt32
    var kind: Kind
    /// Position in the picture, 0…1 from the top-left corner.
    var x: Double
    var y: Double
    /// Scroll distance; positive moves the content right / down, like a finger dragging it.
    var dx: Double = 0
    var dy: Double = 0
    /// What `dx` / `dy` are measured in.
    var deltaUnit: DeltaUnit = .picture
    /// Trackpad mode (FR-TOUCH-07): the action happens where the Mac's pointer is, and a `move`
    /// moves it by `dx` / `dy` (fractions of the picture). `x` / `y` still carry the receiver's
    /// estimate of the pointer, which Macs that predate this field use instead. Optional so
    /// messages without it still decode.
    var relative: Bool? = nil

    enum DeltaUnit: String, Codable, Sendable {
        /// Fractions of the picture's width / height: touches, so the content follows the finger.
        case picture
        /// Points, as from a mouse wheel or trackpad, scrolled as they are.
        case points
    }
}

/// How a receiver's touches move the Mac's pointer.
nonisolated enum TouchControlMode: String, Codable, CaseIterable, Sendable {
    /// Slide anywhere to move the pointer, tap to click where it is (FR-TOUCH-07). The default:
    /// the finger doesn't hide the pointer.
    case trackpad
    /// The pointer jumps to the finger (FR-TOUCH-01~04).
    case direct
}

/// Whether the Mac can act on pointer events right now.
nonisolated enum RemoteInputStatus: String, Codable, Sendable {
    case available
    /// SideCast on the Mac hasn't been allowed to control the computer yet.
    case needsPermission
    /// This Mac's SideCast doesn't offer touch control (Mac App Store version).
    case unsupported
}

/// Where the picture sits in a view that shows it letterboxed (aspect fit).
nonisolated enum PictureGeometry {
    static func fittedRect(picture: CGSize, in bounds: CGSize) -> CGRect {
        guard picture.width > 0, picture.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / picture.width, bounds.height / picture.height)
        let size = CGSize(width: picture.width * scale, height: picture.height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// A point in the view (origin top-left) as a fraction of the picture, or nil if it is on
    /// the black bars.
    static func normalized(_ point: CGPoint, picture: CGSize, in bounds: CGSize) -> CGPoint? {
        let rect = fittedRect(picture: picture, in: bounds)
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    /// Like `normalized`, but clamped to the picture's edge; for drags that leave the picture.
    static func clampedNormalized(_ point: CGPoint, picture: CGSize, in bounds: CGSize) -> CGPoint {
        let rect = fittedRect(picture: picture, in: bounds)
        guard rect.width > 0, rect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(
            x: min(max((point.x - rect.minX) / rect.width, 0), 1),
            y: min(max((point.y - rect.minY) / rect.height, 0), 1)
        )
    }

    /// A view distance as a fraction of the picture's size.
    static func normalizedDelta(_ delta: CGSize, picture: CGSize, in bounds: CGSize) -> CGSize {
        let rect = fittedRect(picture: picture, in: bounds)
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGSize(width: delta.width / rect.width, height: delta.height / rect.height)
    }
}

/// Trackpad mode (FR-TOUCH-07): how far a finger slide moves the Mac's pointer.
nonisolated enum TrackpadMotion {
    /// Finger speed (view points per second) up to which the pointer follows 1:1.
    static let slowSpeed: CGFloat = 200
    /// Finger speed at which the gain reaches `maxGain`.
    static let fastSpeed: CGFloat = 1600
    static let maxGain: CGFloat = 2.5

    /// Slow slides are precise; fast ones cover more of the screen.
    static func gain(speed: CGFloat) -> CGFloat {
        guard speed > slowSpeed else { return 1 }
        let progress = min((speed - slowSpeed) / (fastSpeed - slowSpeed), 1)
        return 1 + (maxGain - 1) * progress
    }

    /// A finger movement in the view as a pointer movement in fractions of the picture: sliding
    /// slowly across the whole picture moves the pointer across the whole Mac display.
    static func pictureDelta(viewDelta: CGSize, velocity: CGPoint, picture: CGSize, in bounds: CGSize) -> CGSize {
        let delta = PictureGeometry.normalizedDelta(viewDelta, picture: picture, in: bounds)
        let gain = gain(speed: hypot(velocity.x, velocity.y))
        return CGSize(width: delta.width * gain, height: delta.height * gain)
    }
}
