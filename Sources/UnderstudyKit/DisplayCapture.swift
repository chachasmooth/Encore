import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Screen Recording permission, which ScreenCaptureKit requires.
///
/// Worth checking up front. Without it, capture still starts and delivers
/// frames, but every frame is black, which looks like a working pipeline
/// producing a broken image rather than a permissions problem.
public enum ScreenRecordingPermission {
    /// Whether permission is granted. Does not prompt.
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS to show the permission dialog, if it has never been answered.
    ///
    /// Returns whether permission is already granted, not what the user chose.
    /// macOS requires the process to be restarted before a newly granted
    /// permission takes effect.
    @discardableResult
    public static func request() -> Bool { CGRequestScreenCaptureAccess() }
}

public enum CaptureError: LocalizedError {
    case permissionDenied
    case displayNotShareable(CGDirectDisplayID)
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission has not been granted. Grant it in System Settings > "
                 + "Privacy & Security > Screen Recording, then run this again."
        case .displayNotShareable(let id):
            return "ScreenCaptureKit does not list display \(id) as shareable."
        case .alreadyRunning:
            return "Capture is already running."
        }
    }
}

/// Pulls frames off a single display.
///
/// The callback receives only frames carrying new content. ScreenCaptureKit also
/// emits frames for a screen that has not changed, and those are counted in
/// `idleFrameCount` rather than delivered, since re-encoding an unchanged screen
/// wastes bandwidth for no visible benefit.
public final class DisplayCapture: NSObject {
    private let displayID: CGDirectDisplayID
    private let pixelWidth: Int
    private let pixelHeight: Int
    private let frameRate: Int

    /// Frames are handled here rather than on the main queue so that a slow
    /// consumer stalls capture instead of the user interface.
    private let outputQueue = DispatchQueue(label: "com.understudy.capture", qos: .userInteractive)

    private var stream: SCStream?
    /// Only ever touched on `outputQueue`, since the delivery callback reads it
    /// there while `start`/`stop` would otherwise write it from another thread.
    private var onFrame: ((CVPixelBuffer) -> Void)?
    private var _idleFrameCount = 0
    /// Set synchronously in `start`, unlike `stream` which is assigned inside a
    /// Task. Without it two quick calls to `start` both pass the guard and the
    /// second stream silently orphans the first, which then captures forever.
    private var started = false

    /// Frames ScreenCaptureKit delivered with nothing new to show. A static
    /// desktop produces these almost exclusively, so a low delivered-frame count
    /// on an idle screen is expected rather than a fault.
    public var idleFrameCount: Int { outputQueue.sync { _idleFrameCount } }

    /// Called if macOS tears the stream down on its own, for example when the
    /// captured display disappears.
    public var onStopped: ((Error) -> Void)?

    public init(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, frameRate: Int = 60) {
        self.displayID = displayID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frameRate = frameRate
        super.init()
    }

    /// Starts capture, calling `onFrame` for every frame with new content.
    ///
    /// Callback-based rather than async because callers drive a run loop and
    /// mixing the two deadlocks. An async wrapper can be added when something
    /// actually wants one.
    ///
    /// Call `start` and `stop` from a single thread.
    public func start(onFrame: @escaping (CVPixelBuffer) -> Void,
                      completion: @escaping (Error?) -> Void) {
        guard !started else { return completion(CaptureError.alreadyRunning) }
        guard ScreenRecordingPermission.isGranted else { return completion(CaptureError.permissionDenied) }
        started = true
        outputQueue.async { self.onFrame = onFrame }

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    throw CaptureError.displayNotShareable(displayID)
                }

                let configuration = SCStreamConfiguration()
                // These are pixels, not points, so they must be the backing size.
                configuration.width = pixelWidth
                configuration.height = pixelHeight
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                // BGRA keeps frames trivial to inspect. Revisit when encoding
                // lands: VideoToolbox takes 4:2:0 YUV with less conversion work.
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                // The spare Mac cannot draw the host's pointer, so it has to be
                // rendered into the frames or it vanishes on the second screen.
                configuration.showsCursor = true
                // A shallow queue keeps latency down. Deeper queues buffer frames
                // that would arrive too late to be worth showing.
                configuration.queueDepth = 3

                let stream = SCStream(
                    filter: SCContentFilter(display: display, excludingWindows: []),
                    configuration: configuration,
                    delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
                try await stream.startCapture()
                self.stream = stream
                completion(nil)
            } catch {
                // Reset so a caller can fix the problem and try again. The
                // callback is deliberately left in place: no stream was created,
                // so nothing can invoke it, and clearing it here would mean
                // touching queue-owned state from inside this Task.
                started = false
                completion(error)
            }
        }
    }

    public func stop(completion: @escaping () -> Void = {}) {
        started = false
        outputQueue.async { self.onFrame = nil }
        guard let stream else { return completion() }
        self.stream = nil
        Task {
            try? await stream.stopCapture()
            completion()
        }
    }
}

extension DisplayCapture: SCStreamOutput {
    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // The frame's status rides along as an attachment. Without checking it,
        // unchanged-screen frames are indistinguishable from real ones.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }

        guard status == .complete, let pixelBuffer = sampleBuffer.imageBuffer else {
            _idleFrameCount += 1
            return
        }
        onFrame?(pixelBuffer)
    }
}

extension DisplayCapture: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }
}
