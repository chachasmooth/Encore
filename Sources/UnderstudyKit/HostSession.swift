import CoreMedia
import CoreVideo
import Foundation

/// The whole host pipeline in one object: virtual display, capture, encode, serve.
///
/// Exists so anything driving the host runs one implementation. Command-line
/// copies of this pipeline existed once and silently fell behind every fix,
/// which is why the app owns no pipeline logic of its own.
public final class HostSession {
    public let pairingCode: String
    public let preset: DisplayPreset
    public let serviceName: String
    public private(set) var position: ScreenPosition

    private var display: VirtualDisplay?
    private var capture: DisplayCapture?
    private var encoder: FrameEncoder?
    private var server: StreamServer?

    private let state = NSLock()
    private var parametersSent = false
    private var needsKeyframe = false
    private var frameIndex: Int64 = 0
    private var _framesSent = 0
    private var _bytesSent = 0
    /// The most recent captured screen, kept so it can be re-sent on demand.
    ///
    /// ScreenCaptureKit only delivers a frame when something changes, so a
    /// still screen produces nothing at all. Without a copy to fall back on, a
    /// client that connects to an idle desktop waits forever for a first frame
    /// and shows nothing.
    private var lastBuffer: CVPixelBuffer?
    private var lastSendTime = Date.distantPast
    private var heartbeat: DispatchSourceTimer?

    public var onClientConnected: (() -> Void)?
    public var onClientDisconnected: ((Error?) -> Void)?

    public var framesSent: Int { state.lock(); defer { state.unlock() }; return _framesSent }
    public var bytesSent: Int { state.lock(); defer { state.unlock() }; return _bytesSent }
    public var droppedFrames: Int { server?.droppedFrames ?? 0 }
    public var isConnected: Bool { server?.isConnected ?? false }

    public init(preset: DisplayPreset,
                position: ScreenPosition = .right,
                serviceName: String = Host.current().localizedName ?? "Understudy Host",
                pairingCode: String = PairingCode.random()) {
        self.preset = preset
        self.position = position
        self.serviceName = serviceName
        self.pairingCode = pairingCode
    }

    public func start(completion: @escaping (Error?) -> Void) {
        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.request()
            return completion(CaptureError.permissionDenied)
        }

        do {
            let display = try VirtualDisplay(preset: preset, name: "Understudy")
            // Placed deliberately. Otherwise macOS puts it on the left, where it
            // collides with wherever Universal Control has the other Mac.
            display.place(position)
            let encoder = try FrameEncoder(pixelWidth: Int(preset.pixelWidth),
                                           pixelHeight: Int(preset.pixelHeight),
                                           frameRate: Int(preset.refreshRate))
            let server = StreamServer(pairingCode: pairingCode, serviceName: serviceName)
            let capture = DisplayCapture(displayID: display.displayID,
                                         pixelWidth: Int(preset.pixelWidth),
                                         pixelHeight: Int(preset.pixelHeight),
                                         frameRate: Int(preset.refreshRate))
            self.display = display
            self.encoder = encoder
            self.server = server
            self.capture = capture

            server.onFrameDropped = { [weak self] in
                guard let self else { return }
                state.lock(); needsKeyframe = true; state.unlock()
            }
            server.onClientConnected = { [weak self] in
                guard let self else { return }
                // A fresh client has no parameter sets and no keyframe, so it can
                // decode nothing that references earlier frames. Start it over,
                // and push the current screen immediately rather than waiting for
                // something on it to move.
                state.lock()
                parametersSent = false
                needsKeyframe = true
                let current = lastBuffer
                state.unlock()

                onClientConnected?()
                if let current { encodeAndSend(current, forceKeyframe: true) }
            }
            server.onClientDisconnected = { [weak self] in self?.onClientDisconnected?($0) }

            server.start { [weak self] error in
                guard let self else { return completion(error) }
                if let error {
                    // The display already exists by this point. Leaving it behind
                    // holds the machine's only virtual display slot, so nothing
                    // else can create one and the user sees a phantom screen with
                    // nothing driving it.
                    stop()
                    return completion(error)
                }
                beginCapturing { [weak self] captureError in
                    if captureError != nil { self?.stop() }
                    completion(captureError)
                }
            }
        } catch {
            stop()
            completion(error)
        }
    }

    private func beginCapturing(completion: @escaping (Error?) -> Void) {
        capture?.start(onFrame: { [weak self] buffer in
            guard let self else { return }
            state.lock(); lastBuffer = buffer; state.unlock()
            guard server?.isConnected == true else { return }
            encodeAndSend(buffer, forceKeyframe: false)
        }, completion: { [weak self] error in
            if error == nil { self?.startHeartbeat() }
            completion(error)
        })
    }

    /// Re-sends the last captured screen when nothing has moved for a while.
    ///
    /// Covers two cases that both otherwise leave the client showing nothing: a
    /// client connecting to a completely still screen, and a client whose
    /// decoder was reset and is waiting for a keyframe that a still screen will
    /// never produce.
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.understudy.heartbeat"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, server?.isConnected == true else { return }
            state.lock()
            let idle = Date().timeIntervalSince(lastSendTime) > 1
            let current = lastBuffer
            state.unlock()
            guard idle, let current else { return }
            encodeAndSend(current, forceKeyframe: true)
        }
        timer.resume()
        heartbeat = timer
    }

    private func encodeAndSend(_ buffer: CVPixelBuffer, forceKeyframe: Bool) {
        guard let server, let encoder, server.isConnected else { return }

        state.lock()
        let time = CMTime(value: frameIndex, timescale: CMTimeScale(preset.refreshRate))
        frameIndex += 1
        let force = forceKeyframe || needsKeyframe
        needsKeyframe = false
        state.unlock()

        encoder.encode(buffer, at: time, forceKeyframe: force) { [weak self] result in
            guard let self,
                  case .success(let sample) = result,
                  let format = CMSampleBufferGetFormatDescription(sample),
                  let payload = sample.encodedData
            else { return }

            state.lock()
            let needsParameters = !parametersSent
            if needsParameters { parametersSent = true }
            state.unlock()

            if needsParameters {
                guard let parameters = VideoParameterSets(formatDescription: format) else { return }
                server.send(.parameters(parameters))
            }
            server.send(.frame(data: payload,
                               presentationTime: CMSampleBufferGetPresentationTimeStamp(sample),
                               isKeyframe: sample.isKeyframe))

            state.lock()
            _framesSent += 1
            _bytesSent += payload.count
            lastSendTime = Date()
            state.unlock()
        }
    }

    /// Moves the second screen to another edge while it is in use.
    ///
    /// Safe mid-stream: the display keeps its identity and the capture session
    /// follows it, so only the arrangement changes.
    @discardableResult
    public func move(to newPosition: ScreenPosition) -> Bool {
        guard display?.place(newPosition) == true else { return false }
        position = newPosition
        return true
    }

    public func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        capture?.stop()
        server?.stop()
        encoder?.invalidate()
        display?.invalidate()
        capture = nil; server = nil; encoder = nil; display = nil; lastBuffer = nil
    }

    deinit { stop() }
}
