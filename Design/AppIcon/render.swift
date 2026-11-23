// Renders the SVG sources to PNGs with AppKit (NSImage reads SVG on macOS 14+).
// Usage: swift render.swift <svg> <png> <size> [mac|grayscale]
import AppKit
import CoreImage

let args = CommandLine.arguments
let source = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let size = Int(args[3])!
let mode = args.count > 4 ? args[4] : "plain"

guard let image = NSImage(contentsOf: source) else { fatalError("cannot load \(source.path)") }
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.interpolationQuality = .high
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
let s = CGFloat(size)

switch mode {
case "mac":
    // macOS icon grid: 824/1024 rounded square, centered slightly high, with a soft shadow.
    let inset = s * 100 / 1024
    let rect = CGRect(x: inset, y: inset + s * 6 / 1024, width: s - 2 * inset, height: s - 2 * inset)
    let radius = rect.width * 0.2237
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 28 / 1024,
                      color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(path)
    context.setFillColor(CGColor(gray: 0.1, alpha: 1))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(path)
    context.clip()
    image.draw(in: rect)
    context.restoreGState()
default:
    image.draw(in: CGRect(x: 0, y: 0, width: s, height: s))
}
NSGraphicsContext.current = nil
var cgImage = context.makeImage()!

if mode == "grayscale" {
    // Tinted appearance: opaque grayscale on black.
    let ci = CIImage(cgImage: cgImage)
    let black = CIImage(color: .black).cropped(to: ci.extent)
    let mono = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputBrightnessKey: 0.05])
        .composited(over: black)
    cgImage = CIContext().createCGImage(mono, from: ci.extent)!
}

if mode == "opaque" {
    // App Store requires the iOS icon without an alpha channel.
    let flat = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    flat.draw(cgImage, in: CGRect(x: 0, y: 0, width: s, height: s))
    cgImage = flat.makeImage()!
}

let rep = NSBitmapImageRep(cgImage: cgImage)
try! rep.representation(using: .png, properties: [:])!.write(to: output)
print("wrote \(output.lastPathComponent) \(size)px")
