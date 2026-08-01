import AppKit
import CoreGraphics
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

heading("Holding")
note("The display is live for \(Int(holdSeconds))s.")
note("Open System Settings > Displays, or drag a window off the right edge, to see it.")
note("Press Ctrl-C to stop early.")

let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    print("\n  Interrupted.")
    display.invalidate()
    exit(problems == 0 ? 0 : 1)
}
interrupt.resume()
signal(SIGINT, SIG_IGN)
pump(holdSeconds)

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
