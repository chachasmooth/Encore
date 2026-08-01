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
public struct DisplayPreset: Sendable, Equatable {
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
    /// Native geometries of recent MacBook panels, expressed as the default
    /// "looks like" point size at 2x.
    public static let macBookAir13 = DisplayPreset(name: "MacBook Air 13\"", pointWidth: 1280, pointHeight: 832)
    public static let macBookAir15 = DisplayPreset(name: "MacBook Air 15\"", pointWidth: 1440, pointHeight: 932)
    public static let macBookPro14 = DisplayPreset(name: "MacBook Pro 14\"", pointWidth: 1512, pointHeight: 982)
    public static let macBookPro16 = DisplayPreset(name: "MacBook Pro 16\"", pointWidth: 1728, pointHeight: 1117)

    public static let all: [DisplayPreset] = [macBookAir13, macBookAir15, macBookPro14, macBookPro16]
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
        guard USVirtualDisplay.isSupported else {
            throw NSError(
                domain: USVirtualDisplayErrorDomain,
                code: USVirtualDisplayError.unsupportedOS.rawValue,
                userInfo: [NSLocalizedDescriptionKey:
                    "This version of macOS does not provide the virtual display API Understudy relies on."])
        }
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
