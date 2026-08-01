import CoreMedia
import Foundation
import Network

/// The client pipeline: find a host, pair, and turn received bytes back into
/// frames ready to hand to a display layer.
///
/// Deliberately stops short of drawing anything, so the app and the
/// command-line tool can share everything except their user interface.
public final class ClientSession {
    private let client: StreamClient
    private let state = NSLock()
    private var format: CMFormatDescription?
    private var connecting = false
    private var _framesReceived = 0
    private var _lastArrival: CFAbsoluteTime?
    private var _gaps: [Double] = []

    /// A decodable frame, in arrival order.
    public var onFrame: ((CMSampleBuffer) -> Void)?
    /// Human-readable progress, suitable for showing on screen.
    public var onStatus: ((String) -> Void)?
    public var onConnected: (() -> Void)?
    public var onDisconnected: ((Error?) -> Void)?

    public var framesReceived: Int { state.lock(); defer { state.unlock() }; return _framesReceived }

    public init(pairingCode: String) {
        client = StreamClient(pairingCode: pairingCode)
        wire()
    }

    /// Gaps between arriving frames since the last call, in milliseconds.
    ///
    /// Only gaps under 100 ms are returned. Longer ones mean the host's screen
    /// had nothing new to show, and counting those as jitter makes an idle
    /// desktop look like a failing connection.
    public func drainFrameGaps() -> [Double] {
        state.lock(); defer { state.unlock() }
        let measured = _gaps.filter { $0 < 100 }
        _gaps.removeAll()
        return measured
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
        }

        client.onConnected = { [weak self] in
            self?.onStatus?("Connected. Waiting for the first frame...")
            self?.onConnected?()
        }

        client.onDisconnected = { [weak self] error in
            guard let self else { return }
            state.lock(); format = nil; connecting = false; state.unlock()
            onDisconnected?(error)
        }

        client.onError = { [weak self] error in
            self?.onStatus?("Error: \(error.localizedDescription)")
        }

        client.onMessage = { [weak self] message in
            guard let self else { return }
            switch message {
            case .parameters(let parameters):
                guard let rebuilt = parameters.makeFormatDescription() else { return }
                state.lock(); format = rebuilt; state.unlock()

            case .frame(let data, let time, _):
                state.lock()
                let current = format
                let now = CFAbsoluteTimeGetCurrent()
                if let last = _lastArrival { _gaps.append((now - last) * 1000) }
                _lastArrival = now
                state.unlock()

                guard let current,
                      let sample = CMSampleBuffer.makeEncodedFrame(
                        data: data, formatDescription: current, presentationTime: time)
                else { return }

                state.lock(); _framesReceived += 1; state.unlock()
                onFrame?(sample)
            }
        }
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
