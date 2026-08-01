import AppKit
import CoreGraphics
import Foundation

/// A snapshot of one screen as macOS currently reports it.
///
/// Reading display geometry on macOS needs three different APIs, because each
/// one is unreliable in a different way:
///
/// - `CGGetActiveDisplayList` / `CGDisplayPixelsWide` are always current, but
///   only report logical point sizes.
/// - `CGDisplayCopyDisplayMode` exposes the true pixel size, but returns nil for
///   freshly created virtual displays in some processes (from Objective-C as
///   well as Swift).
/// - `NSScreen.backingScaleFactor` is correct and public, but `NSScreen.screens`
///   is cached until an AppKit run loop processes a screen-change notification,
///   so it can miss a display that was just added.
///
/// This type therefore enumerates with CoreGraphics and resolves scale from
/// NSScreen, falling back to the display mode. `scaleFactor` is optional because
/// there are moments when no API can answer honestly.
public struct DisplayInfo: Sendable, Equatable {
    public let id: CGDirectDisplayID
    /// Logical size in points, which is what window layout uses.
    public let pointWidth: Int
    public let pointHeight: Int
    /// Nil when the backing scale could not be determined yet.
    public let scaleFactor: Double?
    public let isMain: Bool
    /// True when macOS considers this a built-in laptop panel.
    public let isBuiltIn: Bool
    /// Origin in CoreGraphics' global coordinate space, whose Y axis points down.
    public let origin: CGPoint

    /// Backing store size in real pixels — the number of pixels to encode.
    public var pixelWidth: Int? { scaleFactor.map { Int((Double(pointWidth) * $0).rounded()) } }
    public var pixelHeight: Int? { scaleFactor.map { Int((Double(pointHeight) * $0).rounded()) } }

    public var isHiDPI: Bool? { scaleFactor.map { $0 > 1.5 } }
}

public enum DisplayInfoReader {
    /// IDs of every active display, straight from CoreGraphics.
    ///
    /// Preferred over `NSScreen.screens` when a display may have just been added
    /// or removed, since this reflects the change immediately.
    public static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    public static func activeDisplays() -> [DisplayInfo] {
        activeDisplayIDs().map(info(for:))
    }

    public static func info(for id: CGDirectDisplayID) -> DisplayInfo {
        let pointWidth = Int(CGDisplayPixelsWide(id))
        return DisplayInfo(
            id: id,
            pointWidth: pointWidth,
            pointHeight: Int(CGDisplayPixelsHigh(id)),
            scaleFactor: scaleFactor(for: id, pointWidth: pointWidth),
            isMain: CGDisplayIsMain(id) != 0,
            isBuiltIn: CGDisplayIsBuiltin(id) != 0,
            origin: CGDisplayBounds(id).origin)
    }

    public static func exists(_ id: CGDirectDisplayID) -> Bool {
        activeDisplayIDs().contains(id)
    }

    /// Resolves backing scale, preferring the public API and falling back to the
    /// display mode. Returns nil when neither source can answer.
    private static func scaleFactor(for id: CGDirectDisplayID, pointWidth: Int) -> Double? {
        if let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
            return Double(screen.backingScaleFactor)
        }
        var pixelWidth: UInt32 = 0, pixelHeight: UInt32 = 0
        if USReadDisplayPixelSize(id, &pixelWidth, &pixelHeight), pointWidth > 0 {
            return Double(pixelWidth) / Double(pointWidth)
        }
        return nil
    }
}

extension NSScreen {
    /// The CoreGraphics display ID backing this screen, used to target it for capture.
    public var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

extension DisplayInfo: CustomStringConvertible {
    public var description: String {
        var tags: [String] = []
        if isMain { tags.append("main") }
        if isBuiltIn { tags.append("built-in") }
        switch isHiDPI {
        case .some(true): tags.append("HiDPI")
        case .some(false): tags.append("1x")
        case .none: tags.append("scale unknown")
        }
        let pixels = pixelWidth.flatMap { w in pixelHeight.map { "\(w)×\($0) px" } } ?? "— px"
        let scale = scaleFactor.map { String(format: "@%.1fx", $0) } ?? "@?"
        return String(format: "#%-4u %5d×%-5d pts  %13@  %-5@  @(%.0f, %.0f)  [%@]",
                      id, pointWidth, pointHeight, pixels as NSString, scale as NSString,
                      origin.x, origin.y, tags.joined(separator: ", "))
    }
}
