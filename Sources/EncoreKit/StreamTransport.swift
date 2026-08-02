import CryptoKit
import Foundation
import Network

/// The short code a user reads off the host and types on the client.
///
/// It is not a password protecting an account, it is a one-session secret that
/// both ends turn into the same TLS pre-shared key. Anything that cannot derive
/// that key cannot complete the handshake, so an unpaired machine on the same
/// network never gets as far as receiving a frame.
public enum PairingCode {
    public static func random() -> String {
        String(format: "%06u", UInt32.random(in: 0..<1_000_000))
    }

    /// Derives the shared key. The prefix keeps this key distinct from anything
    /// else the same digits might be used for.
    static func preSharedKey(for code: String) -> Data {
        Data(SHA256.hash(data: Data("encore-pairing-v1:\(code)".utf8)))
    }
}

public enum StreamTransport {
    /// Bonjour service type both ends use to find each other.
    public static let serviceType = "_encore._tcp"

    static func parameters(pairingCode: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = PairingCode.preSharedKey(for: pairingCode)
        let identity = Data("encore".utf8)

        key.withUnsafeBytes { keyBytes in
            identity.withUnsafeBytes { identityBytes in
                sec_protocol_options_add_pre_shared_key(
                    tls.securityProtocolOptions,
                    DispatchData(bytes: keyBytes) as __DispatchData,
                    DispatchData(bytes: identityBytes) as __DispatchData)
            }
        }
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions, tls_ciphersuite_t.AES_128_GCM_SHA256)

        let tcp = NWProtocolTCP.Options()
        // Nagle's algorithm holds small writes back to batch them, which is
        // exactly wrong here: a frame delayed to save a packet is a frame late.
        tcp.noDelay = true
        tcp.connectionTimeout = 5

        return NWParameters(tls: tls, tcp: tcp)
    }
}

// MARK: - Host

/// Advertises the host over Bonjour and streams frames to one paired client.
public final class StreamServer {
    /// How many sends may be outstanding before frames start being dropped.
    ///
    /// A queue is latency: every frame waiting behind another is a frame the
    /// viewer sees late. Better to discard and show the newest.
    private static let maxInFlight = 2

    private let pairingCode: String
    private let serviceName: String
    private let queue = DispatchQueue(label: "com.encore.server")

    /// Marks `queue` so code can tell whether it is already running on it.
    ///
    /// Callbacks like `onClientConnected` fire on `queue`, and handlers
    /// reasonably want to ask whether a client is connected or to stop the
    /// server. Both used `queue.sync`, which traps instantly when called from
    /// the queue itself. Rather than making every caller remember that, the two
    /// accessors below run inline when already on the queue.
    private static let queueKey = DispatchSpecificKey<Void>()

    private func onQueue<T>(_ work: () -> T) -> T {
        DispatchQueue.getSpecific(key: Self.queueKey) != nil ? work() : queue.sync(execute: work)
    }

    private var listener: NWListener?
    private var connection: NWConnection?
    private var inFlight = 0

    /// Frames discarded because the link could not keep up.
    public private(set) var droppedFrames = 0

    /// Called when a frame is dropped. The host should force a keyframe on the
    /// next encode: HEVC frames reference earlier ones, so a gap corrupts the
    /// picture until a self-contained frame arrives.
    public var onFrameDropped: (() -> Void)?
    public var onClientConnected: (() -> Void)?
    public var onClientDisconnected: ((Error?) -> Void)?
    public var onError: ((Error) -> Void)?

    public init(pairingCode: String, serviceName: String) {
        self.pairingCode = pairingCode
        self.serviceName = serviceName
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    public func start(completion: @escaping (Error?) -> Void) {
        do {
            let listener = try NWListener(using: StreamTransport.parameters(pairingCode: pairingCode))
            listener.service = NWListener.Service(name: serviceName,
                                                  type: StreamTransport.serviceType)
            // Reported exactly once. Previously only .ready and .failed were
            // handled, so a listener stuck in .waiting never reported anything
            // and the host looked started while nothing was accepting
            // connections. The display was already created by then, so it sat
            // there as a phantom screen.
            var reported = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !reported else { return }
                switch state {
                case .ready:
                    reported = true
                    completion(nil)
                case .failed(let error):
                    reported = true
                    completion(error)
                    self?.onError?(error)
                case .waiting(let error):
                    // A local listener that cannot bind is usually Local Network
                    // permission being refused, which otherwise fails silently.
                    reported = true
                    completion(error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.adopt(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            completion(error)
        }
    }

    /// Port the listener ended up on, once ready. Useful for connecting directly
    /// when Bonjour discovery is not wanted, such as a loopback test.
    public var port: UInt16? { listener?.port?.rawValue }

    private func adopt(_ incoming: NWConnection) {
        // One client for now. A second would need its own virtual display
        // anyway, which macOS does not currently allow in a single process.
        guard connection == nil else {
            incoming.cancel()
            return
        }
        connection = incoming
        incoming.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                onClientConnected?()
            case .failed(let error):
                connection = nil
                onClientDisconnected?(error)
            case .cancelled:
                connection = nil
                onClientDisconnected?(nil)
            default:
                break
            }
        }
        incoming.start(queue: queue)
    }

    public var isConnected: Bool {
        onQueue { connection?.state == .ready }
    }

    /// Sends a message, dropping it if the link is already behind.
    ///
    /// Parameter sets are never dropped: without them the client cannot decode
    /// anything at all, so they are worth waiting for.
    public func send(_ message: StreamMessage) {
        queue.async { [weak self] in
            guard let self, let connection, connection.state == .ready else { return }

            if case .frame = message, inFlight >= Self.maxInFlight {
                droppedFrames += 1
                onFrameDropped?()
                return
            }

            inFlight += 1
            connection.send(content: message.encoded(),
                            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                queue.async { self.inFlight -= 1 }
                if let error { self.onError?(error) }
            })
        }
    }

    public func stop() {
        onQueue {
            connection?.cancel()
            connection = nil
            listener?.cancel()
            listener = nil
        }
    }
}

// MARK: - Client

/// Finds a host over Bonjour, pairs with it, and receives frames.
public final class StreamClient {
    private let pairingCode: String
    private let queue = DispatchQueue(label: "com.encore.client")

    // Same reentrancy trap as the server: drainBuffer calls disconnect() on a
    // malformed message, and drainBuffer already runs on this queue.
    private static let queueKey = DispatchSpecificKey<Void>()

    private func onQueue<T>(_ work: () -> T) -> T {
        DispatchQueue.getSpecific(key: Self.queueKey) != nil ? work() : queue.sync(execute: work)
    }

    private var browser: NWBrowser?
    private var connection: NWConnection?
    /// TCP delivers a byte stream with no message boundaries, so partial
    /// messages accumulate here until a whole one is available.
    private var buffer = Data()

    public var onMessage: ((StreamMessage) -> Void)?
    public var onConnected: (() -> Void)?
    public var onDisconnected: ((Error?) -> Void)?
    public var onError: ((Error) -> Void)?
    /// Connection is stuck retrying rather than failing outright. Usually a host
    /// that is advertising but not listening, or a wrong pairing code.
    public var onWaiting: ((NWError) -> Void)?
    /// Reports hosts as Bonjour finds them, for a picker.
    public var onHostsChanged: (([NWBrowser.Result]) -> Void)?

    public init(pairingCode: String) {
        self.pairingCode = pairingCode
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    /// Starts looking for hosts on the local network.
    public func browse() {
        let browser = NWBrowser(for: .bonjour(type: StreamTransport.serviceType, domain: nil),
                                using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.onHostsChanged?(Array(results))
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.onError?(error) }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func connect(to endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint,
                                      using: StreamTransport.parameters(pairingCode: pairingCode))
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                onConnected?()
                receive()
            case .failed(let error):
                onDisconnected?(error)
            case .cancelled:
                onDisconnected?(nil)
            case .waiting(let error):
                // Network framework retries a waiting connection forever without
                // ever reaching .failed. Left unreported it looks exactly like a
                // successful connection that has gone quiet, so it has to be
                // surfaced or a wrong code and a dead host are indistinguishable
                // from working.
                onWaiting?(error)
            default:
                break
            }
        }
        self.connection = connection
        connection.start(queue: queue)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                buffer.append(data)
                drainBuffer()
            }
            if let error {
                onError?(error)
                return
            }
            if isComplete {
                onDisconnected?(nil)
                return
            }
            receive()
        }
    }

    private func drainBuffer() {
        do {
            while let message = try StreamMessage.decode(from: &buffer) {
                onMessage?(message)
            }
        } catch {
            // A malformed message means the stream is no longer trustworthy,
            // since every following message is framed relative to this one.
            onError?(error)
            disconnect()
        }
    }

    public func disconnect() {
        onQueue {
            connection?.cancel()
            connection = nil
            browser?.cancel()
            browser = nil
            buffer.removeAll()
        }
    }
}
