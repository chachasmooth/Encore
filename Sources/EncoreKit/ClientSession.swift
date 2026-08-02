import CoreMedia
import CoreVideo
import Foundation
import Network

/// The client pipeline: find a host, pair, and turn received bytes back into
/// frames ready to hand to a display layer.
///
/// Deliberately stops short of drawing anything, so anything that wants to
/// display the stream shares everything except its user interface.
public final class ClientSession {
    private let client: StreamClient
    private let state = NSLock()
    private var format: CMFormatDescription?
    private var connecting = false
    private var connected = false
    private var attempt: DispatchWorkItem?
    private var awaitingKeyframe = false
    private var _framesReceived = 0
    private var _keyframesReceived = 0
    /// Second decoder, used once per connection and never for display.
    ///
    /// `AVSampleBufferDisplayLayer` decodes privately and shows black when that
    /// fails, so a broken stream and an empty desktop look identical from the
    /// outside while the frame counter climbs in both. This decodes the same
    /// bitstream somewhere the result can be measured and written to a file.
    private let inspector = FrameDecoder()
    private var inspected = false

    /// A decodable frame, in arrival order.
    public var onFrame: ((CMSampleBuffer) -> Void)?
    /// Human-readable progress, suitable for showing on screen.
    public var onStatus: ((String) -> Void)?
    public var onConnected: (() -> Void)?
    public var onDisconnected: ((Error?) -> Void)?
    /// What the first keyframe of this connection actually decoded to, once.
    public var onFirstKeyframeInspected: ((String) -> Void)?

    public var framesReceived: Int { state.lock(); defer { state.unlock() }; return _framesReceived }
    /// Keyframes specifically. A stream with frames but no keyframes cannot be
    /// decoded at all, and is indistinguishable from a healthy one by frame count.
    public var keyframesReceived: Int { state.lock(); defer { state.unlock() }; return _keyframesReceived }

    public init(pairingCode: String) {
        client = StreamClient(pairingCode: pairingCode)
        wire()
    }

    private func wire() {
        client.onHostsChanged = { [weak self] results in
            guard let self, let first = results.first else { return }
            state.lock()
            let alreadyConnecting = connecting
            connecting = true
            state.unlock()
            guard !alreadyConnecting else { return }

            if case let .service(name, _, _, _) = first.endpoint {
                onStatus?("Found \(name). Pairing...")
            }
            client.connect(to: first.endpoint)

            // Bonjour records outlive the process that published them, so a
            // host that has stopped is still advertised and NWConnection will
            // retry that dead address forever rather than failing. Without a
            // deadline the client simply sits on "Pairing..." indefinitely.
            let deadline = DispatchWorkItem { [weak self] in
                guard let self else { return }
                state.lock()
                let stillTrying = !connected
                if stillTrying { connecting = false }
                state.unlock()
                guard stillTrying else { return }
                client.disconnect()
                onStatus?("No answer from that Mac. Check it still has \"Extend this Mac\" running, then try again.")
            }
            attempt?.cancel()
            attempt = deadline
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
        }

        client.onConnected = { [weak self] in
            guard let self else { return }
            state.lock(); connected = true; state.unlock()
            attempt?.cancel()
            onStatus?("Connected. Waiting for the first frame...")
            onConnected?()
        }

        client.onDisconnected = { [weak self] error in
            guard let self else { return }
            state.lock(); format = nil; connecting = false; connected = false; state.unlock()
            onDisconnected?(error)
        }

        client.onError = { [weak self] error in
            self?.onStatus?("Error: \(error.localizedDescription)")
        }

        client.onWaiting = { [weak self] error in
            // Almost always one of two things, and the user can act on both, so
            // say them rather than showing the raw network error.
            self?.onStatus?("""
            Cannot reach the host. Check that the other Mac has \
            "Extend this Mac" running and started, and that the code matches. \
            (\(error.localizedDescription))
            """)
        }

        client.onMessage = { [weak self] message in
            guard let self else { return }
            switch message {
            case .parameters(let parameters):
                guard let rebuilt = parameters.makeFormatDescription() else { return }
                state.lock(); format = rebuilt; state.unlock()

            case .frame(let data, let time, let isKeyframe):
                state.lock()
                let current = format
                // After the display layer is flushed its decoder has nothing to
                // reference, so a delta frame fails and triggers another flush,
                // forever. Skip ahead to the next self-contained frame instead.
                if awaitingKeyframe && !isKeyframe {
                    state.unlock()
                    return
                }
                if isKeyframe { awaitingKeyframe = false }
                state.unlock()

                guard let current,
                      let sample = CMSampleBuffer.makeEncodedFrame(
                        data: data, formatDescription: current, presentationTime: time)
                else { return }

                state.lock()
                _framesReceived += 1
                if isKeyframe { _keyframesReceived += 1 }
                // Only a keyframe is worth inspecting. A delta frame on its own
                // legitimately decodes to nothing, so a failure there would prove
                // nothing about the stream.
                let inspect = isKeyframe && !inspected
                if inspect { inspected = true }
                state.unlock()

                onFrame?(sample)
                if inspect { inspectKeyframe(sample) }
            }
        }
    }

    /// Decodes one keyframe and reports what came out, including a PNG on disk.
    ///
    /// Three outcomes, and they mean different things. A decode failure says the
    /// bytes reaching the client are not a usable stream. A successful decode with
    /// a peak of zero says the host is genuinely sending black. Anything brighter
    /// says the picture arrives intact and the fault is in showing it.
    private func inspectKeyframe(_ sample: CMSampleBuffer) {
        inspector.decode(sample) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                onFirstKeyframeInspected?("keyframe did not decode: \(error.localizedDescription)")
            case .success(let buffer):
                let (mean, peak) = FrameInspection.brightness(buffer)
                let path = FrameInspection.savePNG(buffer, named: "client-keyframe.png")
                onFirstKeyframeInspected?(String(
                    format: "keyframe %dx%d  mean %.3f  peak %d  %@",
                    CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
                    mean, peak, path ?? "(png not written)"))
            }
        }
    }

    /// Call after flushing the display layer, so frames resume from the next
    /// self-contained one rather than from a delta the decoder cannot use.
    public func resyncAfterFlush() {
        state.lock(); awaitingKeyframe = true; state.unlock()
    }

    public func start() {
        onStatus?("Looking for a host on this network...")
        client.browse()
    }

    public func stop() {
        client.disconnect()
    }

    deinit { stop() }
}
