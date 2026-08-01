import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import UnderstudyKit

// A diagnostic tool, not part of the shipping app. It creates a virtual display,
// confirms macOS registered it with the requested geometry, holds it open so the
// result is visible in System Settings > Displays, then tears it down and checks
// that it disappeared.
//
//   swift run understudy-probe [seconds]

let holdSeconds = CommandLine.arguments.count > 1
    ? (Double(CommandLine.arguments[1]) ?? 20)
    : 20

func heading(_ text: String) {
    print("\n\u{001B}[1m\(text)\u{001B}[0m")
    print(String(repeating: "─", count: max(text.count, 44)))
}

func pass(_ text: String) { print("  \u{001B}[32m✓\u{001B}[0m \(text)") }
func fail(_ text: String) { print("  \u{001B}[31m✗\u{001B}[0m \(text)") }
func note(_ text: String) { print("    \(text)") }

// Note: deliberately no NSApplication bootstrap. Initialising AppKit enumerates
// screens, which would cache a screen list from before the virtual display
// existed — and a bare run loop never refreshes it. A real GUI app is unaffected
// because it creates its displays after NSApp is already running.

/// Brightness summary of a BGRA frame.
///
/// `peak` is what actually distinguishes a working capture from a broken one.
/// Without Screen Recording permission macOS still delivers correctly sized
/// frames, but every channel is zero. A working capture of an *empty* virtual
/// display is also nearly black, because a display with no wallpaper and no
/// windows on it really is black apart from the menu bar, so `mean` stays near
/// zero in both cases and cannot tell them apart. A non-zero peak can only come
/// from real pixels.
func frameBrightness(_ buffer: CVPixelBuffer) -> (mean: Double, peak: Int) {
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

/// Writes a frame to a PNG and returns where it went.
///
/// Being able to look at what was actually captured is what turned "the frames
/// are black" from a guess into an answer, so the probe always leaves one behind.
func saveFrame(_ buffer: CVPixelBuffer) -> String? {
    let image = CIImage(cvPixelBuffer: buffer)
    guard let cgImage = CIContext().createCGImage(image, from: image.extent),
          let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    else { return nil }

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("understudy-frame.png")
    do {
        try data.write(to: url)
        return url.path
    } catch {
        return nil
    }
}

/// Runs the run loop for a while so pending notifications land.
func pump(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

heading("Environment")
note("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

guard USVirtualDisplay.isSupported else {
    fail("The private virtual display API is not available on this system.")
    note("Understudy cannot work here. This usually means a macOS update removed it.")
    exit(1)
}
pass("Private virtual display API is present")

heading("Displays before")
let idsBefore = Set(DisplayInfoReader.activeDisplayIDs())
// Deliberately CoreGraphics-only. Reading NSScreen before the virtual display
// exists caches a stale screen list that a bare run loop never refreshes, which
// would make the display look non-Retina later on.
for id in idsBefore.sorted() {
    let bounds = CGDisplayBounds(id)
    note(String(format: "#%-4u %5d×%-5d pts  @(%.0f, %.0f)", id,
                CGDisplayPixelsWide(id), CGDisplayPixelsHigh(id),
                bounds.origin.x, bounds.origin.y))
}

let preset = DisplayPreset.macBookPro14

heading("Creating virtual display")
note("Requesting \(preset.name): \(preset.pointWidth)×\(preset.pointHeight) pts "
     + "@\(preset.scaleFactor)x = \(preset.pixelWidth)×\(preset.pixelHeight) px, "
     + String(format: "%.0fHz", preset.refreshRate))

let display: VirtualDisplay
do {
    display = try VirtualDisplay(preset: preset, name: "Understudy Probe")
} catch {
    fail("Creation failed: \(error.localizedDescription)")
    exit(1)
}
pass("Created — display ID \(display.displayID)")

display.onTerminated = { fail("macOS terminated the display unexpectedly.") }

// Let AppKit catch up before measuring.
pump(0.5)

heading("Verifying macOS sees it")
var problems = 0

let idsAfter = Set(DisplayInfoReader.activeDisplayIDs())
if idsAfter.subtracting(idsBefore).contains(display.displayID) {
    pass("Appears in the active display list")
} else {
    fail("Not in the active display list — created but never registered")
    problems += 1
}

let info = DisplayInfoReader.info(for: display.displayID)
note(info.description)

if info.pointWidth == Int(preset.pointWidth), info.pointHeight == Int(preset.pointHeight) {
    pass("Logical resolution matches: \(info.pointWidth)×\(info.pointHeight) pts")
} else {
    fail("Logical resolution is \(info.pointWidth)×\(info.pointHeight) pts, "
         + "expected \(preset.pointWidth)×\(preset.pointHeight)")
    problems += 1
}

switch (info.pixelWidth, info.pixelHeight) {
case let (width?, height?) where width == Int(preset.pixelWidth) && height == Int(preset.pixelHeight):
    pass("Backing resolution matches: \(width)×\(height) px")
case let (width?, height?):
    fail("Backing resolution is \(width)×\(height) px, "
         + "expected \(preset.pixelWidth)×\(preset.pixelHeight)")
    problems += 1
default:
    fail("Could not determine backing resolution from any API")
    problems += 1
}

switch info.isHiDPI {
case .some(true):
    pass(String(format: "Retina/HiDPI confirmed (%.1fx scale)", info.scaleFactor ?? 0))
case .some(false):
    fail(String(format: "Not HiDPI — scale is %.1fx, text will look soft", info.scaleFactor ?? 0))
    problems += 1
case .none:
    fail("Could not determine scale factor")
    problems += 1
}

if !info.isMain, !info.isBuiltIn {
    pass("Reported as a secondary external display")
} else {
    fail("Unexpectedly reported as main or built-in")
    problems += 1
}

heading("Capturing frames")

if !ScreenRecordingPermission.isGranted {
    fail("Screen Recording permission has not been granted")
    note("macOS should be showing a permission dialog now. Approve the terminal")
    note("in System Settings > Privacy & Security > Screen Recording, restart it,")
    note("then run this again. Capture cannot be tested until then.")
    ScreenRecordingPermission.request()
    problems += 1
} else {
    pass("Screen Recording permission granted")

    let capture = DisplayCapture(displayID: display.displayID,
                                 pixelWidth: Int(preset.pixelWidth),
                                 pixelHeight: Int(preset.pixelHeight))
    capture.onStopped = { fail("Capture stopped on its own: \($0.localizedDescription)") }

    // Frames arrive on a background queue, so everything they touch is locked.
    let lock = NSLock()
    var frameCount = 0
    var firstFrame: (width: Int, height: Int, mean: Double, peak: Int)?
    var savedFramePath: String?
    var startFinished = false
    var startError: Error?

    capture.start(onFrame: { buffer in
        lock.lock()
        frameCount += 1
        let needsMeasurement = firstFrame == nil
        lock.unlock()

        guard needsMeasurement else { return }
        let brightness = frameBrightness(buffer)
        let measured = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
                        brightness.mean, brightness.peak)
        let path = saveFrame(buffer)
        lock.lock()
        if firstFrame == nil {
            firstFrame = measured
            savedFramePath = path
        }
        lock.unlock()
    }, completion: { error in
        lock.lock()
        startError = error
        startFinished = true
        lock.unlock()
    })

    let startDeadline = Date().addingTimeInterval(10)
    while Date() < startDeadline {
        lock.lock(); let done = startFinished; lock.unlock()
        if done { break }
        pump(0.05)
    }

    lock.lock(); let failure = startError; let finished = startFinished; lock.unlock()

    if !finished {
        fail("Capture did not start within 10s")
        problems += 1
    } else if let failure {
        fail("Capture failed to start: \(failure.localizedDescription)")
        problems += 1
    } else {
        pass("Capture started")
        note("Capturing for \(Int(holdSeconds))s. The display is live meanwhile, so")
        note("open System Settings > Displays or drag a window onto it to see it.")
        pump(holdSeconds)

        lock.lock()
        let frames = frameCount
        let first = firstFrame
        let framePath = savedFramePath
        lock.unlock()
        let idle = capture.idleFrameCount
        capture.stop()

        if let first {
            pass("Frames are arriving")

            if first.width == Int(preset.pixelWidth), first.height == Int(preset.pixelHeight) {
                pass("Frame size matches the display: \(first.width)×\(first.height) px")
            } else {
                fail("Frames are \(first.width)×\(first.height) px, "
                     + "expected \(preset.pixelWidth)×\(preset.pixelHeight)")
                problems += 1
            }

            // Peak, not mean. A virtual display with no wallpaper and no windows
            // on it is genuinely almost black, so its mean brightness looks
            // identical to a permission failure. Only a non-zero peak proves
            // real pixels came back.
            if first.peak > 32 {
                pass(String(format: "Frames contain real pixels (peak %d, mean %.4f)",
                            first.peak, first.mean))
            } else {
                fail("Frames are entirely black (peak \(first.peak))")
                note("Usually means Screen Recording permission belongs to a different app")
                note("than the one running this. Check the saved frame below to be sure.")
                problems += 1
            }

            if let framePath {
                note("First frame written to \(framePath)")
                note("Open it to see exactly what was captured.")
            }
        } else {
            fail("No frames with new content arrived in \(Int(holdSeconds))s")
            problems += 1
        }

        note("\(frames) frames with new content, \(idle) unchanged")
        note("An empty desktop changes nothing, so most frames being idle is correct.")
    }
}

heading("Tearing down")
let idBeforeTeardown = display.displayID
display.invalidate()
pump(0.5)

if DisplayInfoReader.exists(idBeforeTeardown) {
    fail("Display \(idBeforeTeardown) is still registered after invalidate()")
    problems += 1
} else {
    pass("Display removed cleanly")
}

heading(problems == 0 ? "Result: all checks passed" : "Result: \(problems) problem(s)")
exit(problems == 0 ? 0 : 1)
