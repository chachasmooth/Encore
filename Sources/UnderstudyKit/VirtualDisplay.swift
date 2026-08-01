import AppKit
import CoreGraphics
import Foundation

@_exported import CVirtualDisplay

/// A screen geometry the host can present to the client MacBook.
///
/// Point size is what macOS treats as the usable resolution; multiplying by
/// `scaleFactor` gives the real pixel count that has to be encoded and sent.
/// Matching a preset to the client's native panel avoids a resampling step and
/// keeps text crisp.
public struct DisplayPreset: Sendable, Hashable {
    public let name: String
    public let pointWidth: UInt32
    public let pointHeight: UInt32
    public let scaleFactor: UInt32
    public let refreshRate: Double

    public init(name: String,
                pointWidth: UInt32,
                pointHeight: UInt32,
                scaleFactor: UInt32 = 2,
                refreshRate: Double = 60) {
        self.name = name
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.scaleFactor = scaleFactor
        self.refreshRate = refreshRate
    }

    public var pixelWidth: UInt32 { pointWidth * scaleFactor }
    public var pixelHeight: UInt32 { pointHeight * scaleFactor }
}

extension DisplayPreset {
    // Every MacBook panel from the M1 to the M5, as the point size that lands
    // exactly on the panel's real pixels at 2x. Matching one means the client
    // does no rescaling, which is both sharper and cheaper.
    //
    // Six models, five resolutions: the 13.3-inch Air and the 13.3-inch Pro
    // share a panel. Apple has not moved any of these numbers in five years, so
    // the M5 machines match their M1 and M2 equivalents exactly.
    //
    // Verified against Apple's published specifications rather than memory,
    // after the 13-inch Air was briefly wrong here.
    //
    // MacBook Neo is deliberately absent. It is 2408×1506, but it runs an A18
    // Pro rather than an M-series chip and has no Thunderbolt at all, so it
    // cannot join a Thunderbolt Bridge. It becomes supportable once transport
    // stops requiring a cable.

    /// 2560×1600. MacBook Air 13.3-inch (M1) and MacBook Pro 13.3-inch (M1, M2).
    public static let macBook13 = DisplayPreset(name: "13.3-inch (M1 Air, M1/M2 Pro)",
                                                pointWidth: 1280, pointHeight: 800)
    /// 2560×1664. MacBook Air 13.6-inch (M2 onwards).
    public static let macBookAir13_6 = DisplayPreset(name: "MacBook Air 13.6-inch",
                                                     pointWidth: 1280, pointHeight: 832)
    /// 2880×1864. MacBook Air 15.3-inch (M2 onwards).
    public static let macBookAir15 = DisplayPreset(name: "MacBook Air 15-inch",
                                                   pointWidth: 1440, pointHeight: 932)
    /// 3024×1964. MacBook Pro 14.2-inch (M1 Pro onwards, unchanged through M5 Max).
    public static let macBookPro14 = DisplayPreset(name: "MacBook Pro 14-inch",
                                                   pointWidth: 1512, pointHeight: 982)
    /// 3456×2234. MacBook Pro 16.2-inch (M1 Pro onwards, unchanged through M5 Max).
    public static let macBookPro16 = DisplayPreset(name: "MacBook Pro 16-inch",
                                                   pointWidth: 1728, pointHeight: 1117)

    public static let all: [DisplayPreset] = [
        macBook13, macBookAir13_6, macBookAir15, macBookPro14, macBookPro16,
    ]
}

/// Which edge of the main screen the second display sits against.
///
/// Worth choosing rather than accepting. Left to itself macOS drops a new
/// virtual display on the left, which collides with wherever Universal Control
/// has put a nearby Mac, and the only way out is dragging rectangles around in
/// System Settings.
public enum ScreenPosition: String, CaseIterable, Sendable {
    case left, right, above, below

    public var label: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .above: return "Above"
        case .below: return "Below"
        }
    }

    /// The edge a window is dragged through to reach it, which is not always the
    /// same word: a screen placed "above" is reached through the top edge.
    public var edgeName: String {
        switch self {
        case .left: return "left"
        case .right: return "right"
        case .above: return "top"
        case .below: return "bottom"
        }
    }
}

/// Swift-facing wrapper around the private-API virtual display.
///
/// The display exists for as long as this object is retained, so the host must
/// hold onto it. Everything that touches private API lives in `USVirtualDisplay`.
public final class VirtualDisplay {
    private let backing: USVirtualDisplay
    public let preset: DisplayPreset

    /// Creates a virtual monitor matching `preset`.
    /// - Throws: `USVirtualDisplayError` if macOS refuses or the private API has changed shape.
    public init(preset: DisplayPreset, name: String = "Understudy Display") throws {
        // No isSupported check here on purpose: the initialiser below already
        // verifies the private classes exist and throws unsupportedOS itself.
        self.backing = try USVirtualDisplay(
            name: name,
            widthPoints: preset.pointWidth,
            heightPoints: preset.pointHeight,
            scaleFactor: preset.scaleFactor,
            refreshRate: preset.refreshRate)
        self.preset = preset
        // Required, not just defensive: AppKit caches NSScreen.screens until the
        // run loop turns, so without this the new display stays invisible to the
        // rest of the process.
        waitUntilReady()
    }

    /// Blocks until macOS reports the geometry that was asked for, or until
    /// `timeout` elapses.
    ///
    /// WindowServer registers a new display at a provisional resolution and
    /// switches to the requested mode shortly afterwards. Reading geometry
    /// immediately after creation therefore reports the wrong size, and starting
    /// a capture session that early yields frames at the wrong dimensions.
    ///
    /// - Returns: true if the display settled at the expected size.
    @discardableResult
    public func waitUntilReady(timeout: TimeInterval = 3.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let info = DisplayInfoReader.info(for: displayID)
            if info.pixelWidth == Int(preset.pixelWidth),
               info.pixelHeight == Int(preset.pixelHeight) {
                return true
            }
            // Turning the run loop rather than sleeping lets AppKit refresh its
            // cached screen list, which is what publishes the new display.
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }

    /// Moves the display to the chosen side of the main screen.
    ///
    /// Applied for this session only. The arrangement is Understudy's to set
    /// each time it runs, rather than something it should write permanently into
    /// the user's system display preferences.
    @discardableResult
    public func place(_ position: ScreenPosition) -> Bool {
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        // CoreGraphics puts the origin top-left with y increasing downwards, so
        // "above" is a smaller y, not a larger one.
        let origin: CGPoint
        switch position {
        case .left:  origin = CGPoint(x: mainBounds.minX - CGFloat(preset.pointWidth), y: mainBounds.minY)
        case .right: origin = CGPoint(x: mainBounds.maxX, y: mainBounds.minY)
        case .above: origin = CGPoint(x: mainBounds.minX, y: mainBounds.minY - CGFloat(preset.pointHeight))
        case .below: origin = CGPoint(x: mainBounds.minX, y: mainBounds.maxY)
        }

        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success,
              let configuration else { return false }

        guard CGConfigureDisplayOrigin(configuration, displayID,
                                       Int32(origin.x), Int32(origin.y)) == .success else {
            CGCancelDisplayConfiguration(configuration)
            return false
        }
        return CGCompleteDisplayConfiguration(configuration, .forSession) == .success
    }

    /// CoreGraphics ID used to target this screen for capture.
    public var displayID: CGDirectDisplayID { backing.displayID }

    /// Invoked on the main queue if macOS tears the display down unprompted.
    public var onTerminated: (() -> Void)? {
        get { backing.terminationHandler }
        set { backing.terminationHandler = newValue }
    }

    /// Removes the display immediately rather than waiting for deinit.
    public func invalidate() { backing.invalidate() }
}
