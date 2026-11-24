//
//  RemoteInputTests.swift
//  SideCastTests
//
//  Touch control (FR-TOUCH): picture geometry, the pointer messages, and how the Mac turns them
//  into mouse events.
//

import CoreGraphics
import Foundation
import Testing
@testable import SideCast

struct PictureGeometryTests {
    let picture = CGSize(width: 1600, height: 1000)  // 16:10 Mac screen

    @Test func letterboxesInATallerView() {
        // 4:3 iPad: bars above and below.
        let rect = PictureGeometry.fittedRect(picture: picture, in: CGSize(width: 1024, height: 768))
        #expect(rect.width == 1024)
        #expect(rect.height == 640)
        #expect(rect.minY == 64)
    }

    @Test func normalizesPointsOnThePicture() {
        let bounds = CGSize(width: 1024, height: 768)
        #expect(PictureGeometry.normalized(CGPoint(x: 512, y: 384), picture: picture, in: bounds) == CGPoint(x: 0.5, y: 0.5))
        #expect(PictureGeometry.normalized(CGPoint(x: 0, y: 64), picture: picture, in: bounds) == CGPoint(x: 0, y: 0))
        // On the black bar.
        #expect(PictureGeometry.normalized(CGPoint(x: 512, y: 20), picture: picture, in: bounds) == nil)
        #expect(PictureGeometry.clampedNormalized(CGPoint(x: 512, y: 20), picture: picture, in: bounds) == CGPoint(x: 0.5, y: 0))
    }

    @Test func normalizesDistances() {
        let delta = PictureGeometry.normalizedDelta(CGSize(width: 102.4, height: -64), picture: picture, in: CGSize(width: 1024, height: 768))
        #expect(abs(delta.width - 0.1) < 1e-9)
        #expect(abs(delta.height + 0.1) < 1e-9)
    }
}

struct PointerMessageTests {
    @Test func pointerAndStatusRoundTrip() throws {
        let messages: [ControlMessage] = [
            .pointer(PointerEvent(streamID: 7, kind: .scroll, x: 0.25, y: 0.75, dx: 0.01, dy: -0.02)),
            .remoteInputStatus(streamID: 7, status: .needsPermission),
        ]
        for message in messages {
            let decoded = try JSONDecoder().decode(ControlMessage.self, from: JSONEncoder().encode(message))
            #expect(decoded == message)
        }
    }
}

#if os(macOS)
struct RemoteInputPlannerTests {
    /// A second display to the right of a 1512-point-wide main display.
    let bounds = CGRect(x: 1512, y: 0, width: 1920, height: 1080)

    func event(_ kind: PointerEvent.Kind, _ x: Double, _ y: Double, dx: Double = 0, dy: Double = 0) -> PointerEvent {
        PointerEvent(streamID: 1, kind: kind, x: x, y: y, dx: dx, dy: dy)
    }

    @Test func tapClicksAtThePointOnTheMirroredDisplay() {
        var planner = RemoteInputPlanner()
        let point = CGPoint(x: 1512 + 960, y: 270)
        #expect(planner.plan(event(.click, 0.5, 0.25), bounds: bounds, time: 0)
            == [.move(point), .leftDown(point, clicks: 1), .leftUp(point, clicks: 1)])
        #expect(!planner.isPressed)
    }

    @Test func quickTapsAreDoubleClicks() {
        var planner = RemoteInputPlanner()
        _ = planner.plan(event(.click, 0.5, 0.5), bounds: bounds, time: 10)
        let second = planner.plan(event(.click, 0.501, 0.5), bounds: bounds, time: 10.2)
        #expect(second.contains(.leftDown(CGPoint(x: 1512 + 961.92, y: 540), clicks: 2)))
        // Too late, or too far away: a single click again.
        let late = planner.plan(event(.click, 0.5, 0.5), bounds: bounds, time: 11)
        #expect(late.contains { if case .leftDown(_, 1) = $0 { true } else { false } })
        let far = planner.plan(event(.click, 0.9, 0.5), bounds: bounds, time: 11.1)
        #expect(far.contains { if case .leftDown(_, 1) = $0 { true } else { false } })
    }

    @Test func dragsHoldTheButton() {
        var planner = RemoteInputPlanner()
        let start = CGPoint(x: 1512, y: 0)
        let end = CGPoint(x: 1512 + 1920, y: 1080)
        #expect(planner.plan(event(.down, 0, 0), bounds: bounds, time: 0) == [.move(start), .leftDown(start, clicks: 1)])
        #expect(planner.plan(event(.move, 1, 1), bounds: bounds, time: 0.1) == [.leftDrag(end, clicks: 1)])
        #expect(planner.plan(event(.up, 1, 1), bounds: bounds, time: 0.2) == [.leftUp(end, clicks: 1)])
        // Moves without a press only move the pointer; a stray release does nothing.
        #expect(planner.plan(event(.move, 1, 1), bounds: bounds, time: 0.3) == [.move(end)])
        #expect(planner.plan(event(.up, 1, 1), bounds: bounds, time: 0.4).isEmpty)
    }

    @Test func clampsPointsToTheDisplay() {
        var planner = RemoteInputPlanner()
        #expect(planner.plan(event(.move, -0.5, 2), bounds: bounds, time: 0) == [.move(CGPoint(x: 1512, y: 1080))])
    }

    @Test func rightClicks() {
        var planner = RemoteInputPlanner()
        let point = CGPoint(x: 1512 + 192, y: 108)
        #expect(planner.plan(event(.rightClick, 0.1, 0.1), bounds: bounds, time: 0) == [.move(point), .rightDown(point), .rightUp(point)])
    }

    @Test func scrollsByPixelsAndKeepsTheRemainder() {
        var planner = RemoteInputPlanner()
        let point = CGPoint(x: 1512 + 960, y: 540)
        // 10% of 1080 points down.
        #expect(planner.plan(event(.scroll, 0.5, 0.5, dy: 0.1), bounds: bounds, time: 0) == [.move(point), .scroll(dx: 0, dy: 108)])
        // Half a pixel each time: nothing, then one pixel.
        let half = 0.5 / 1080
        #expect(planner.plan(event(.scroll, 0.5, 0.5, dy: half), bounds: bounds, time: 0).isEmpty)
        #expect(planner.plan(event(.scroll, 0.5, 0.5, dy: half), bounds: bounds, time: 0) == [.move(point), .scroll(dx: 0, dy: 1)])
    }

    @Test func scrollsMouseWheelDistancesAsTheyAre() {
        var planner = RemoteInputPlanner()
        var wheel = event(.scroll, 0.5, 0.5, dx: 3, dy: -40)
        wheel.deltaUnit = .points
        #expect(planner.plan(wheel, bounds: bounds, time: 0).last == .scroll(dx: 3, dy: -40))
    }

    @Test func releasesAHeldButtonWhenMirroringStops() {
        var planner = RemoteInputPlanner()
        _ = planner.plan(event(.down, 0.5, 0.5), bounds: bounds, time: 0)
        #expect(planner.release(bounds: bounds) == [.leftUp(CGPoint(x: bounds.midX, y: bounds.midY), clicks: 1)])
        #expect(planner.release(bounds: bounds).isEmpty)
    }

    @Test func onlyTheWebsiteVersionInjects() {
        #expect(RemoteInputInjector.isSupported == (RuntimeEnvironment.distribution == .website))
    }
}
#endif
