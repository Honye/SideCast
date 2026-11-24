//
//  RemoteInputInjector.swift
//  SideCast
//
//  Touch control on the Mac side (FR-TOUCH, website version only): turns a receiver's pointer
//  events into mouse events on the mirrored display. Posting events needs the user's approval
//  in System Settings › Privacy & Security › Accessibility.
//

#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import os

/// One mouse action to post, in global display coordinates (points, origin top-left of the
/// main display).
nonisolated enum SyntheticInput: Equatable {
    case move(CGPoint)
    case leftDown(CGPoint, clicks: Int)
    case leftDrag(CGPoint, clicks: Int)
    case leftUp(CGPoint, clicks: Int)
    case rightDown(CGPoint)
    case rightUp(CGPoint)
    /// Pixels; positive `dy` scrolls the content down (toward the top of the document).
    case scroll(dx: Int32, dy: Int32)
}

/// Turns pointer events into mouse actions. Keeps the button state and counts quick
/// successive presses as double / triple clicks.
nonisolated struct RemoteInputPlanner {
    static let multiClickInterval: TimeInterval = 0.4
    static let multiClickDistance: CGFloat = 8

    private(set) var isPressed = false
    private var clickCount = 1
    private var lastPress: (time: TimeInterval, point: CGPoint)?
    private var scrollRemainder = CGSize.zero

    /// `bounds`: the mirrored display in global coordinates.
    mutating func plan(_ event: PointerEvent, bounds: CGRect, time: TimeInterval) -> [SyntheticInput] {
        let point = CGPoint(
            x: bounds.minX + min(max(event.x, 0), 1) * bounds.width,
            y: bounds.minY + min(max(event.y, 0), 1) * bounds.height
        )
        switch event.kind {
        case .down:
            var actions: [SyntheticInput] = []
            if isPressed { actions.append(.leftUp(point, clicks: clickCount)) }
            press(at: point, time: time)
            return actions + [.move(point), .leftDown(point, clicks: clickCount)]
        case .move:
            return [isPressed ? .leftDrag(point, clicks: clickCount) : .move(point)]
        case .up:
            guard isPressed else { return [] }
            isPressed = false
            return [.leftUp(point, clicks: clickCount)]
        case .click:
            var actions: [SyntheticInput] = []
            if isPressed { actions.append(.leftUp(point, clicks: clickCount)) }
            press(at: point, time: time)
            isPressed = false
            return actions + [.move(point), .leftDown(point, clicks: clickCount), .leftUp(point, clicks: clickCount)]
        case .rightClick:
            lastPress = nil
            return [.move(point), .rightDown(point), .rightUp(point)]
        case .scroll:
            // Whole pixels only; carry the rest so slow scrolls still move.
            let scale = event.deltaUnit == .picture ? bounds.size : CGSize(width: 1, height: 1)
            let total = CGSize(
                width: event.dx * scale.width + scrollRemainder.width,
                height: event.dy * scale.height + scrollRemainder.height
            )
            let dx = Int32(total.width.rounded(.towardZero))
            let dy = Int32(total.height.rounded(.towardZero))
            scrollRemainder = CGSize(width: total.width - CGFloat(dx), height: total.height - CGFloat(dy))
            guard dx != 0 || dy != 0 else { return [] }
            return [.move(point), .scroll(dx: dx, dy: dy)]
        }
    }

    /// Lets go of a held button, e.g. when mirroring stops mid-drag.
    mutating func release(bounds: CGRect) -> [SyntheticInput] {
        guard isPressed else { return [] }
        isPressed = false
        return [.leftUp(CGPoint(x: bounds.midX, y: bounds.midY), clicks: clickCount)]
    }

    private mutating func press(at point: CGPoint, time: TimeInterval) {
        if let last = lastPress,
           time - last.time <= Self.multiClickInterval,
           hypot(point.x - last.point.x, point.y - last.point.y) <= Self.multiClickDistance {
            clickCount = min(clickCount + 1, 3)
        } else {
            clickCount = 1
        }
        lastPress = (time, point)
        isPressed = true
    }
}

/// Posts the planned mouse events. One per mirrored receiver.
final class RemoteInputInjector {
    static var isSupported: Bool { RuntimeEnvironment.distribution == .website }

    /// Debug builds only: `SIDECAST_DRY_INPUT=1` logs pointer events instead of posting them, so
    /// tests don't move the real mouse (and don't need the permission).
    static let isDryRun: Bool = {
#if DEBUG
        ProcessInfo.processInfo.environment["SIDECAST_DRY_INPUT"] == "1"
#else
        false
#endif
    }()

    static var status: RemoteInputStatus {
#if DISTRIBUTION_APP_STORE
        return .unsupported
#else
        return isDryRun || CGPreflightPostEventAccess() ? .available : .needsPermission
#endif
    }

    /// Shows macOS's prompt (once; later it only adds SideCast to the list in System Settings).
    static func requestPermission() {
#if !DISTRIBUTION_APP_STORE
        guard isSupported, !isDryRun else { return }
        _ = CGRequestPostEventAccess()
#endif
    }

    private var planner = RemoteInputPlanner()
    private let source = CGEventSource(stateID: .hidSystemState)

    func handle(_ event: PointerEvent, display: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(display)
        post(planner.plan(event, bounds: bounds, time: ProcessInfo.processInfo.systemUptime))
    }

    func release(display: CGDirectDisplayID) {
        post(planner.release(bounds: CGDisplayBounds(display)))
    }

    private func post(_ actions: [SyntheticInput]) {
        for action in actions {
            if Self.isDryRun {
                Log.input.info("input \(String(describing: action), privacy: .public)")
                DebugTrace.write("input \(action)")
                FileHandle.standardError.write(Data("SideCast dry input: \(action)\n".utf8))
                continue
            }
#if !DISTRIBUTION_APP_STORE
            makeEvent(action)?.post(tap: .cghidEventTap)
#endif
        }
    }

#if !DISTRIBUTION_APP_STORE
    private func makeEvent(_ action: SyntheticInput) -> CGEvent? {
        func mouse(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton, clicks: Int = 1) -> CGEvent? {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            return event
        }
        switch action {
        case .move(let point):
            return mouse(.mouseMoved, point, .left)
        case .leftDown(let point, let clicks):
            return mouse(.leftMouseDown, point, .left, clicks: clicks)
        case .leftDrag(let point, let clicks):
            return mouse(.leftMouseDragged, point, .left, clicks: clicks)
        case .leftUp(let point, let clicks):
            return mouse(.leftMouseUp, point, .left, clicks: clicks)
        case .rightDown(let point):
            return mouse(.rightMouseDown, point, .right)
        case .rightUp(let point):
            return mouse(.rightMouseUp, point, .right)
        case .scroll(let dx, let dy):
            return CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        }
    }
#endif
}
#endif
