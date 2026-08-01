import CoreMedia
import CoreVideo
import Foundation

/// The whole host pipeline in one object: virtual display, capture, encode, serve.
///
/// Exists so the app and the command-line tool run identical code rather than
/// two drifting copies of the same eighty lines.
public final class HostSession {
    public let pairingCode: String
    public let preset: DisplayPreset
    public let serviceName: String

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

    public var onClientConnected: (() -> Void)?
    public var onClientDisconnected: ((Error?) -> Void)?

    public var framesSent: Int { state.lock(); defer { state.unlock() }; return _framesSent }
    public var bytesSent: Int { state.lock(); defer { state.unlock() }; return _bytesSent }
    public var droppedFrames: Int { server?.droppedFrames ?? 0 }
    public var isConnected: Bool { server?.isConnected ?? false }
    public var isHardwareAccelerated: Bool { encoder?.isHardwareAccelerated ?? false }

    public init(preset: DisplayPreset,
                serviceName: String = Host.current().localizedName ?? "Understudy Host",
                pairingCode: String = PairingCode.random()) {
        self.preset = preset
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
                // decode nothing that references earlier frames. Start it over.
                state.lock(); parametersSent = false; needsKeyframe = true; state.unlock()
                onClientConnected?()
            }
            server.onClientDisconnected = { [weak self] in self?.onClientDisconnected?($0) }

            server.start { [weak self] error in
                if let error { return completion(error) }
                self?.beginCapturing(completion: completion)
            }
        } catch {
            completion(error)
        }
    }

    private func beginCapturing(completion: @escaping (Error?) -> Void) {
        capture?.start(onFrame: { [weak self] buffer in
            guard let self, let server, let encoder, server.isConnected else { return }

            state.lock()
            let time = CMTime(value: frameIndex, timescale: CMTimeScale(preset.refreshRate))
            frameIndex += 1
            let forceKeyframe = needsKeyframe
            needsKeyframe = false
            state.unlock()

            encoder.encode(buffer, at: time, forceKeyframe: forceKeyframe) { [weak self] result in
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

                state.lock(); _framesSent += 1; _bytesSent += payload.count; state.unlock()
            }
        }, completion: completion)
    }

    public func stop() {
        capture?.stop()
        server?.stop()
        encoder?.invalidate()
        display?.invalidate()
        capture = nil; server = nil; encoder = nil; display = nil
    }

    deinit { stop() }
}
