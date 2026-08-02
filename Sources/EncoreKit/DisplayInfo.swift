import AppKit
import CoreGraphics
import Foundation

/// A snapshot of one screen as macOS currently reports it.
///
/// Geometry comes from two APIs, because neither answers everything:
///
/// - `CGGetActiveDisplayList` / `CGDisplayPixelsWide` are always current, but
///   only report logical point sizes.
/// - `NSScreen.backingScaleFactor` gives the backing scale, but
///   `NSScreen.screens` is cached until an AppKit run loop processes a
///   screen-change notification, so it can miss a display that was just added.
///
/// `CGDisplayCopyDisplayMode` looks like an obvious third source for true pixel
/// size and was tried as a fallback. It returns nil for freshly created virtual
/// displays, including in the exact case where NSScreen is stale, so it rescued
/// nothing and was removed. Don't re-add it. `scaleFactor` is optional because
/// there are moments when neither remaining source can answer honestly.
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
            scaleFactor: scaleFactor(for: id),
            isMain: CGDisplayIsMain(id) != 0,
            isBuiltIn: CGDisplayIsBuiltin(id) != 0,
            origin: CGDisplayBounds(id).origin)
    }

    public static func exists(_ id: CGDirectDisplayID) -> Bool {
        activeDisplayIDs().contains(id)
    }

    /// Backing scale, or nil when AppKit's cached screen list does not yet
    /// include this display.
    private static func scaleFactor(for id: CGDirectDisplayID) -> Double? {
        NSScreen.screens.first { $0.displayID == id }.map { Double($0.backingScaleFactor) }
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
