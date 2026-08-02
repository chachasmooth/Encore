import AppKit
import CoreImage
import CoreVideo
import Foundation

/// Looking at actual pixels rather than reasoning about them.
///
/// Every wrong answer about the black-screen bug came from arguing over what the
/// frames probably contained. Both right answers came from writing a frame to a
/// file and opening it.
public enum FrameInspection {
    /// Brightness summary of a BGRA frame.
    ///
    /// `peak` is what distinguishes a working frame from a broken one. A frame
    /// that failed to decode and a frame of an empty desktop both have a mean
    /// near zero, so the mean alone cannot tell them apart. A non-zero peak can
    /// only come from real pixels.
    public static func brightness(_ buffer: CVPixelBuffer) -> (mean: Double, peak: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (0, 0) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        // Sampling a grid. Six million pixels is far more than this question needs.
        var total = 0.0
        var peak = 0
        var samples = 0
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let offset = y * bytesPerRow + x * 4
                let b = Int(pixels[offset]), g = Int(pixels[offset + 1]), r = Int(pixels[offset + 2])
                peak = max(peak, max(r, max(g, b)))
                total += Double(r + g + b) / 3
                samples += 1
            }
        }
        return (samples > 0 ? total / Double(samples) / 255 : 0, peak)
    }

    /// Writes a frame to `~/Library/Logs/Understudy` and returns where it went.
    ///
    /// Not the temporary directory, which is a path nobody can find, and not the
    /// Desktop, which would trigger a permission prompt on a machine that is
    /// currently showing a fullscreen video window.
    public static func savePNG(_ buffer: CVPixelBuffer, named name: String) -> String? {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else { return nil }

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Understudy")
        let url = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }
}
