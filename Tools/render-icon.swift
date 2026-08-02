import AppKit
import Foundation

// Renders Tools/icon.svg to Tools/icon.png.
//
//   swift Tools/render-icon.swift
//
// Not qlmanage. QuickLook thumbnails are composited onto white, which puts an
// opaque white square around an icon whose corners are supposed to be clear.
// NSImage reads SVG directly on macOS 13 and later, so the artwork is drawn
// into a bitmap that starts empty and anything it does not paint stays
// transparent.

let root = FileManager.default.currentDirectoryPath
let input = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "\(root)/Tools/icon.svg"
let output = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "\(root)/Tools/icon.png"
let size = 1024.0

guard let svg = NSImage(contentsOfFile: input) else {
    FileHandle.standardError.write(Data("Could not read \(input)\n".utf8))
    exit(1)
}

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                              pixelsWide: Int(size), pixelsHigh: Int(size),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current!.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
svg.draw(in: CGRect(x: 0, y: 0, width: size, height: size),
         from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Could not encode the PNG.\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: output))

// A corner that is not transparent means the icon will show a white square on
// any dark background, which is the bug this script exists to avoid.
let check = NSBitmapImageRep(data: png)!.colorAt(x: 4, y: 4)!
guard check.alphaComponent == 0 else {
    FileHandle.standardError.write(Data("Corner pixel is not transparent.\n".utf8))
    exit(1)
}
print("Wrote \(output), corners transparent")
