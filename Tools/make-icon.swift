import AppKit
import Foundation

// Draws Tools/icon.png, the source image for the app icon.
//
//   swift Tools/make-icon.swift
//
// Only needed to regenerate the artwork. Tools/build-app.sh reads the PNG, not
// this file, so replacing Tools/icon.png with any 1024x1024 image is enough to
// change the icon and this can be ignored entirely.

let size = 1024.0

// The macOS icon grid: the shape sits inset inside the canvas rather than
// filling it, which is what makes it line up with everything else in the Dock.
let inset = 96.0
let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let plateRadius = 190.0

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func gradient(_ colors: [(CGFloat, CGFloat, CGFloat)], _ locations: [CGFloat]) -> CGGradient {
    let components: [CGFloat] = colors.flatMap { [$0.0 / 255, $0.1 / 255, $0.2 / 255, CGFloat(1)] }
    return CGGradient(colorSpace: CGColorSpaceCreateDeviceRGB(),
                      colorComponents: components,
                      locations: locations,
                      count: locations.count)!
}

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                              pixelsWide: Int(size), pixelsHigh: Int(size),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let ctx = NSGraphicsContext.current!.cgContext

// Top-left origin, so everything below reads the way the image looks.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// MARK: Plate

ctx.saveGState()
ctx.addPath(rounded(plate, plateRadius))
ctx.clip()
ctx.drawLinearGradient(gradient([(69, 75, 86), (26, 29, 36), (9, 11, 15)], [0, 0.55, 1]),
                       start: CGPoint(x: plate.midX, y: plate.minY),
                       end: CGPoint(x: plate.midX, y: plate.maxY),
                       options: [])
ctx.restoreGState()

// MARK: The second screen, glowing

let second = CGRect(x: 578, y: 392, width: 250, height: 256)

ctx.saveGState()
ctx.addPath(rounded(plate, plateRadius))
ctx.clip()   // the glow stops at the plate edge rather than bleeding onto the canvas
// Two passes. One blur wide enough to read as light spilling across the plate
// leaves a visible ring at its own edge; a second tighter pass fills the gap
// between that and the rectangle.
for (blur, alpha) in [(170.0, 0.30), (70.0, 0.22)] {
    ctx.setShadow(offset: .zero, blur: blur,
                  color: CGColor(red: 245 / 255, green: 158 / 255, blue: 45 / 255, alpha: alpha))
    ctx.addPath(rounded(second, 30))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()
}
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(rounded(second, 30))
ctx.clip()
ctx.drawLinearGradient(gradient([(253, 205, 124), (238, 143, 38)], [0, 1]),
                       start: CGPoint(x: second.minX, y: second.minY),
                       end: CGPoint(x: second.maxX, y: second.maxY),
                       options: [])
ctx.restoreGState()

// MARK: The Mac being extended

let screen = CGRect(x: 196, y: 314, width: 350, height: 346)
let stroke = 27.0

ctx.addPath(rounded(screen.insetBy(dx: stroke / 2, dy: stroke / 2), 34))
ctx.setFillColor(CGColor(red: 28 / 255, green: 31 / 255, blue: 38 / 255, alpha: 1))
ctx.fillPath()

ctx.addPath(rounded(screen.insetBy(dx: stroke / 2, dy: stroke / 2), 34))
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineWidth(stroke)
ctx.strokePath()

// The base, drawn wide enough to sit under both screens.
let base = CGRect(x: 200, y: 701, width: 624, height: 31)
ctx.addPath(rounded(base, base.height / 2))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fillPath()

NSGraphicsContext.restoreGraphicsState()

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1]
                 : FileManager.default.currentDirectoryPath + "/Tools/icon.png")
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Could not encode the PNG.\n".utf8))
    exit(1)
}
try data.write(to: output)
print("Wrote \(output.path)")
