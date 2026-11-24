//
//  VirtualDisplay.swift
//  SideCast
//
//  Extended display (FR-SCREEN-02, website version only): a virtual display the receiver shows,
//  so windows can be dragged onto it. macOS has no public API for this; it uses CoreGraphics'
//  CGVirtualDisplay classes (the same ones DeskPad and BetterDisplay use), looked up at runtime.
//  Tested to work inside the App Sandbox on macOS 27.2.
//

#if os(macOS)
import CoreGraphics
import Foundation
import os

#if !DISTRIBUTION_APP_STORE
@objc private protocol VirtualDisplayObject: NSObjectProtocol {
    init(descriptor: AnyObject)
    func applySettings(_ settings: AnyObject) -> Bool
    var displayID: UInt32 { get }
}

@objc private protocol VirtualDisplayModeObject: NSObjectProtocol {
    init(width: UInt32, height: UInt32, refreshRate: Double)
}
#endif

/// Sizes for a receiver's extended display.
nonisolated enum ExtendedDisplayLayout {
    /// Modes in points, Retina (2×). The first is used at first: the receiver's own size, so
    /// things look as big as in its apps; the others give more space and appear in System
    /// Settings › Displays.
    static func modes(receiverPixels: CGSize) -> [CGSize] {
        let landscape = CGSize(width: max(receiverPixels.width, receiverPixels.height), height: min(receiverPixels.width, receiverPixels.height))
        return [2, 1.6, 1.333].map { divisor in
            CGSize(width: even(landscape.width / divisor), height: even(landscape.height / divisor))
        }
    }

    /// Stable per receiver, so macOS remembers where the display is arranged.
    static func serialNumber(for receiver: UUID) -> UInt32 {
        let bytes = withUnsafeBytes(of: receiver.uuid) { Array($0) }
        let value = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return value == 0 ? 1 : value
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded() * 2)
    }
}

/// One virtual display. It goes away when this object is released; macOS then moves its
/// windows to another display.
final class VirtualDisplay {
    static let vendorID: UInt32 = 0x5343 // "SC"
    /// Website version only; the Mac App Store version doesn't contain the private API at all.
    static var isSupported: Bool {
#if DISTRIBUTION_APP_STORE
        return false
#else
        return NSClassFromString("CGVirtualDisplay") != nil
#endif
    }

    let displayID: CGDirectDisplayID
    let receiverPixels: CGSize
#if !DISTRIBUTION_APP_STORE
    private let display: VirtualDisplayObject
#endif

    init?(name: String, receiver: UUID, receiverPixels: CGSize) {
#if DISTRIBUTION_APP_STORE
        return nil
#else
        guard Self.isSupported,
              let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay"),
              let modeClass = NSClassFromString("CGVirtualDisplayMode") else { return nil }
        let modes = ExtendedDisplayLayout.modes(receiverPixels: receiverPixels)
        let largest = modes.max { $0.width < $1.width } ?? receiverPixels

        let descriptor = descriptorClass.init()
        descriptor.setValue(name, forKey: "name")
        descriptor.setValue(Int(largest.width * 2), forKey: "maxPixelsWide")
        descriptor.setValue(Int(largest.height * 2), forKey: "maxPixelsHigh")
        // Physical size only affects what macOS reports; assume a tablet-like 264 ppi.
        let millimetersPerPixel = 25.4 / 264
        descriptor.setValue(
            NSValue(size: CGSize(width: receiverPixels.width * millimetersPerPixel, height: receiverPixels.height * millimetersPerPixel)),
            forKey: "sizeInMillimeters"
        )
        descriptor.setValue(Self.vendorID, forKey: "vendorID")
        descriptor.setValue(1, forKey: "productID")
        descriptor.setValue(ExtendedDisplayLayout.serialNumber(for: receiver), forKey: "serialNum")
        descriptor.setValue(DispatchQueue(label: "SideCast.virtualDisplay"), forKey: "queue")

        let displayType = unsafeBitCast(displayClass, to: VirtualDisplayObject.Type.self)
        let modeType = unsafeBitCast(modeClass, to: VirtualDisplayModeObject.Type.self)
        let display = displayType.init(descriptor: descriptor)
        let settings = settingsClass.init()
        settings.setValue(1, forKey: "hiDPI")
        settings.setValue(modes.map { modeType.init(width: UInt32($0.width), height: UInt32($0.height), refreshRate: 60) }, forKey: "modes")
        guard display.displayID != 0, display.applySettings(settings) else {
            Log.app.error("Could not create a virtual display")
            return nil
        }
        self.display = display
        self.displayID = display.displayID
        self.receiverPixels = receiverPixels
        Log.app.info("Extended display \(display.displayID) for \(name, privacy: .public): \(Int(modes[0].width))x\(Int(modes[0].height)) points")
#endif
    }

    /// Waits until macOS has the display online with a mode (it appears asynchronously).
    func waitUntilOnline(timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if CGDisplayIsOnline(displayID) != 0, CGDisplayCopyDisplayMode(displayID) != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Whether a display is one of SideCast's extended displays (not offered for mirroring).
    static func isExtendedDisplay(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == vendorID && CGDisplayModelNumber(id) == 1
    }
}
#endif
