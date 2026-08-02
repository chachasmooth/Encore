import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Network
import EncoreKit

// A diagnostic tool, not part of the shipping app. It creates a virtual display,
// confirms macOS registered it with the requested geometry, holds it open so the
// result is visible in System Settings > Displays, then tears it down and checks
// that it disappeared.
//
//   swift run encore-probe [seconds]

let holdSeconds = CommandLine.arguments.count > 1
    ? (Double(CommandLine.arguments[1]) ?? 20)
    : 20

func heading(_ text: String) {
    print("\n\u{001B}[1m\(text)\u{001B}[0m")
    print(String(repeating: "─", count: max(text.count, 44)))
}

func pass(_ text: String) { print("  \u{001B}[32m✓\u{001B}[0m \(text)") }
func fail(_ text: String) { print("  \u{001B}[31m✗\u{001B}[0m \(text)") }
func note(_ text: String) { print("    \(text)") }

// Note: deliberately no NSApplication bootstrap. Initialising AppKit enumerates
// screens, which would cache a screen list from before the virtual display
// existed — and a bare run loop never refreshes it. A real GUI app is unaffected
// because it creates its displays after NSApp is already running.

/// Runs the run loop for a while so pending notifications land.
func pump(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

heading("Environment")
note("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

guard ENVirtualDisplay.isSupported else {
    fail("The private virtual display API is not available on this system.")
    note("Encore cannot work here. This usually means a macOS update removed it.")
    exit(1)
}
pass("Private virtual display API is present")

heading("Displays before")
let idsBefore = Set(DisplayInfoReader.activeDisplayIDs())
// Deliberately CoreGraphics-only. Reading NSScreen before the virtual display
// exists caches a stale screen list that a bare run loop never refreshes, which
// would make the display look non-Retina later on.
for id in idsBefore.sorted() {
    let bounds = CGDisplayBounds(id)
    note(String(format: "#%-4u %5d×%-5d pts  @(%.0f, %.0f)", id,
                CGDisplayPixelsWide(id), CGDisplayPixelsHigh(id),
                bounds.origin.x, bounds.origin.y))
}

// Targets the client MacBook's panel, not this one, since that is the geometry
// that will actually be encoded and sent.
let preset = DisplayPreset.macBook13

heading("Creating virtual display")
note("Requesting \(preset.name): \(preset.pointWidth)×\(preset.pointHeight) pts "
     + "@\(preset.scaleFactor)x = \(preset.pixelWidth)×\(preset.pixelHeight) px, "
     + String(format: "%.0fHz", preset.refreshRate))

let display: VirtualDisplay
do {
    display = try VirtualDisplay(preset: preset, name: "Encore Probe")
} catch {
    fail("Creation failed: \(error.localizedDescription)")
    exit(1)
}
pass("Created — display ID \(display.displayID)")

display.onTerminated = { fail("macOS terminated the display unexpectedly.") }

// Let AppKit catch up before measuring.
pump(0.5)

heading("Verifying macOS sees it")
var problems = 0

let idsAfter = Set(DisplayInfoReader.activeDisplayIDs())
if idsAfter.subtracting(idsBefore).contains(display.displayID) {
    pass("Appears in the active display list")
} else {
    fail("Not in the active display list — created but never registered")
    problems += 1
}

let info = DisplayInfoReader.info(for: display.displayID)
note(info.description)

if info.pointWidth == Int(preset.pointWidth), info.pointHeight == Int(preset.pointHeight) {
    pass("Logical resolution matches: \(info.pointWidth)×\(info.pointHeight) pts")
} else {
    fail("Logical resolution is \(info.pointWidth)×\(info.pointHeight) pts, "
         + "expected \(preset.pointWidth)×\(preset.pointHeight)")
    problems += 1
}

switch (info.pixelWidth, info.pixelHeight) {
case let (width?, height?) where width == Int(preset.pixelWidth) && height == Int(preset.pixelHeight):
    pass("Backing resolution matches: \(width)×\(height) px")
case let (width?, height?):
    fail("Backing resolution is \(width)×\(height) px, "
         + "expected \(preset.pixelWidth)×\(preset.pixelHeight)")
    problems += 1
default:
    fail("Could not determine backing resolution from any API")
    problems += 1
}

switch info.isHiDPI {
case .some(true):
    pass(String(format: "Retina/HiDPI confirmed (%.1fx scale)", info.scaleFactor ?? 0))
case .some(false):
    fail(String(format: "Not HiDPI — scale is %.1fx, text will look soft", info.scaleFactor ?? 0))
    problems += 1
case .none:
    fail("Could not determine scale factor")
    problems += 1
}

if !info.isMain, !info.isBuiltIn {
    pass("Reported as a secondary external display")
} else {
    fail("Unexpectedly reported as main or built-in")
    problems += 1
}

heading("Capturing frames")

var captureVerified = false

if !ScreenRecordingPermission.isGranted {
    fail("Screen Recording permission has not been granted")
    note("macOS should be showing a permission dialog now. Approve the terminal")
    note("in System Settings > Privacy & Security > Screen Recording, restart it,")
    note("then run this again. Capture cannot be tested until then.")
    ScreenRecordingPermission.request()
    problems += 1
} else {
    pass("Screen Recording permission granted")

    let capture = DisplayCapture(displayID: display.displayID,
                                 pixelWidth: Int(preset.pixelWidth),
                                 pixelHeight: Int(preset.pixelHeight))
    capture.onStopped = { fail("Capture stopped on its own: \($0.localizedDescription)") }

    // Frames arrive on a background queue, so everything they touch is locked.
    let lock = NSLock()
    var frameCount = 0
    var firstFrame: (width: Int, height: Int, mean: Double, peak: Int)?
    var savedFramePath: String?
    var startFinished = false
    var startError: Error?

    capture.start(onFrame: { buffer in
        lock.lock()
        frameCount += 1
        let needsMeasurement = firstFrame == nil
        lock.unlock()

        guard needsMeasurement else { return }
        let brightness = FrameInspection.brightness(buffer)
        let measured = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
                        brightness.mean, brightness.peak)
        let path = FrameInspection.savePNG(buffer, named: "probe-capture.png")
        lock.lock()
        if firstFrame == nil {
            firstFrame = measured
            savedFramePath = path
        }
        lock.unlock()
    }, completion: { error in
        lock.lock()
        startError = error
        startFinished = true
        lock.unlock()
    })

    let startDeadline = Date().addingTimeInterval(10)
    while Date() < startDeadline {
        lock.lock(); let done = startFinished; lock.unlock()
        if done { break }
        pump(0.05)
    }

    lock.lock(); let failure = startError; let finished = startFinished; lock.unlock()

    if !finished {
        fail("Capture did not start within 10s")
        problems += 1
    } else if let failure {
        fail("Capture failed to start: \(failure.localizedDescription)")
        problems += 1
    } else {
        pass("Capture started")
        note("Capturing for \(Int(holdSeconds))s. The display is live meanwhile, so")
        note("open System Settings > Displays or drag a window onto it to see it.")
        pump(holdSeconds)

        lock.lock()
        let frames = frameCount
        let first = firstFrame
        let framePath = savedFramePath
        lock.unlock()
        let idle = capture.idleFrameCount
        capture.stop()

        if let first {
            pass("Frames are arriving")

            if first.width == Int(preset.pixelWidth), first.height == Int(preset.pixelHeight) {
                pass("Frame size matches the display: \(first.width)×\(first.height) px")
                captureVerified = true
            } else {
                fail("Frames are \(first.width)×\(first.height) px, "
                     + "expected \(preset.pixelWidth)×\(preset.pixelHeight)")
                problems += 1
            }

            // Peak, not mean. A virtual display with no wallpaper and no windows
            // on it is genuinely almost black, so its mean brightness looks
            // identical to a permission failure. Only a non-zero peak proves
            // real pixels came back.
            if first.peak > 32 {
                pass(String(format: "Frames contain real pixels (peak %d, mean %.4f)",
                            first.peak, first.mean))
            } else {
                fail("Frames are entirely black (peak \(first.peak))")
                note("Usually means Screen Recording permission belongs to a different app")
                note("than the one running this. Check the saved frame below to be sure.")
                problems += 1
            }

            if let framePath {
                note("First frame written to \(framePath)")
                note("Open it to see exactly what was captured.")
            }
        } else {
            fail("No frames with new content arrived in \(Int(holdSeconds))s")
            problems += 1
        }

        note("\(frames) frames with new content, \(idle) unchanged")
        note("An empty desktop changes nothing, so most frames being idle is correct.")
    }
}

heading("Encoding and decoding")

// Kept from the encode stage and replayed over a real socket below, so the
// transport is tested against genuine frames rather than synthetic bytes.
var outboundMessages: [StreamMessage] = []

if !captureVerified {
    note("Skipped, since capture did not produce usable frames.")
} else {
    do {
        let encoder = try FrameEncoder(pixelWidth: Int(preset.pixelWidth),
                                       pixelHeight: Int(preset.pixelHeight),
                                       frameRate: Int(preset.refreshRate))
        let decoder = FrameDecoder()
        pass("HEVC encoder and decoder created")

        if encoder.isHardwareAccelerated {
            pass("Encoder is hardware accelerated")
        } else {
            fail("Encoder fell back to software, which roughly doubles frame time")
            problems += 1
        }

        let lock = NSLock()
        var encodedCount = 0
        var decodedCount = 0
        var keyframes = 0
        var encodedBytes = 0
        var encodeNanos: UInt64 = 0
        var decodeNanos: UInt64 = 0
        var firstError: String?
        var sourceStats: (mean: Double, peak: Int)?
        var decodedStats: (width: Int, height: Int, mean: Double, peak: Int)?
        var frameIndex: Int64 = 0
        // Rebuilt on the receiving side of the wire format, exactly as a client
        // would have to. Nil until the parameter sets have been through it.
        var wireFormat: CMFormatDescription?
        var wireBytes = 0
        var wireFrames = 0

        func record(_ problem: String) {
            lock.lock()
            if firstError == nil { firstError = problem }
            lock.unlock()
        }

        let capture = DisplayCapture(displayID: display.displayID,
                                     pixelWidth: Int(preset.pixelWidth),
                                     pixelHeight: Int(preset.pixelHeight))

        capture.start(onFrame: { buffer in
            // Measured before encoding so the source buffer never has to outlive
            // this callback; ScreenCaptureKit recycles it from a pool.
            let source = FrameInspection.brightness(buffer)

            lock.lock()
            let time = CMTime(value: frameIndex, timescale: CMTimeScale(preset.refreshRate))
            frameIndex += 1
            lock.unlock()

            let encodeStart = DispatchTime.now().uptimeNanoseconds
            encoder.encode(buffer, at: time) { result in
                let encodeEnd = DispatchTime.now().uptimeNanoseconds
                switch result {
                case .failure(let error):
                    lock.lock()
                    if firstError == nil { firstError = error.localizedDescription }
                    lock.unlock()

                case .success(let sample):
                    lock.lock()
                    encodedCount += 1
                    encodedBytes += sample.encodedByteCount
                    encodeNanos += encodeEnd - encodeStart
                    if sample.isKeyframe { keyframes += 1 }
                    let needsParameters = wireFormat == nil
                    lock.unlock()

                    // Serialise the frame into the exact bytes the network will
                    // carry, then read it back the way a client must. Decoding
                    // the encoder's own sample buffer would skip all of this and
                    // prove nothing about the wire format.
                    guard let format = CMSampleBufferGetFormatDescription(sample),
                          let payload = sample.encodedData else {
                        record("could not read the encoded frame")
                        return
                    }

                    var messages: [StreamMessage] = []
                    if needsParameters {
                        guard let parameters = VideoParameterSets(formatDescription: format) else {
                            record("could not extract HEVC parameter sets")
                            return
                        }
                        messages.append(.parameters(parameters))
                    }
                    messages.append(.frame(
                        data: payload,
                        presentationTime: CMSampleBufferGetPresentationTimeStamp(sample),
                        isKeyframe: sample.isKeyframe))

                    var wire = Data()
                    for message in messages { wire.append(message.encoded()) }

                    lock.lock()
                    wireBytes += wire.count
                    if outboundMessages.count < 40 { outboundMessages.append(contentsOf: messages) }
                    lock.unlock()

                    var rebuilt: CMSampleBuffer?
                    do {
                        while let message = try StreamMessage.decode(from: &wire) {
                            switch message {
                            case .parameters(let parameters):
                                guard let received = parameters.makeFormatDescription() else {
                                    record("could not rebuild the format description from the wire")
                                    return
                                }
                                lock.lock(); wireFormat = received; lock.unlock()

                            case .frame(let data, let time, _):
                                lock.lock(); let received = wireFormat; lock.unlock()
                                guard let received else {
                                    record("a frame arrived before any parameter sets")
                                    return
                                }
                                rebuilt = CMSampleBuffer.makeEncodedFrame(
                                    data: data, formatDescription: received, presentationTime: time)
                            }
                        }
                    } catch {
                        record("wire format: \(error.localizedDescription)")
                        return
                    }

                    guard let rebuilt else {
                        record("nothing came back out of the wire format")
                        return
                    }
                    lock.lock(); wireFrames += 1; lock.unlock()

                    let decodeStart = DispatchTime.now().uptimeNanoseconds
                    decoder.decode(rebuilt) { decoded in
                        let decodeEnd = DispatchTime.now().uptimeNanoseconds
                        switch decoded {
                        case .failure(let error):
                            lock.lock()
                            if firstError == nil { firstError = error.localizedDescription }
                            lock.unlock()

                        case .success(let pixels):
                            let stats = FrameInspection.brightness(pixels)
                            let size = (CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels))
                            lock.lock()
                            decodedCount += 1
                            decodeNanos += decodeEnd - decodeStart
                            if decodedStats == nil {
                                sourceStats = source
                                decodedStats = (size.0, size.1, stats.mean, stats.peak)
                            }
                            lock.unlock()
                        }
                    }
                }
            }
        }, completion: { error in
            if let error {
                fail("Capture failed to restart: \(error.localizedDescription)")
                problems += 1
            }
        })

        pump(min(holdSeconds, 8))
        encoder.flush()
        pump(0.4)
        capture.stop()

        lock.lock()
        let encoded = encodedCount, decoded = decodedCount, keys = keyframes
        let bytes = encodedBytes, encodeTime = encodeNanos, decodeTime = decodeNanos
        let error = firstError, source = sourceStats, result = decodedStats
        let throughWire = wireFrames, wireTotal = wireBytes
        lock.unlock()

        if let error {
            fail("Coding error: \(error)")
            problems += 1
        }

        if encoded > 0 {
            pass("\(encoded) frames encoded (\(keys) keyframes)")
        } else {
            fail("No frames were encoded")
            problems += 1
        }

        if throughWire > 0, throughWire == encoded {
            pass("\(throughWire) frames survived the wire format intact")
        } else if throughWire > 0 {
            fail("Only \(throughWire) of \(encoded) frames survived the wire format")
            problems += 1
        } else {
            fail("No frames survived the wire format")
            problems += 1
        }

        if decoded > 0 {
            pass("\(decoded) frames decoded back after serialising")
        } else {
            fail("No frames were decoded")
            problems += 1
        }

        if let result {
            if result.width == Int(preset.pixelWidth), result.height == Int(preset.pixelHeight) {
                pass("Decoded frames are full size: \(result.width)×\(result.height) px")
            } else {
                fail("Decoded frames are \(result.width)×\(result.height) px, "
                     + "expected \(preset.pixelWidth)×\(preset.pixelHeight)")
                problems += 1
            }

            // HEVC is lossy, so the round trip will not be identical. What
            // matters is that the picture survived rather than arriving blank or
            // scrambled, so compare against the source frame's own numbers.
            if let source {
                let peakDrift = abs(Double(result.peak - source.peak)) / Double(max(source.peak, 1))
                if result.peak > 32, peakDrift < 0.35 {
                    pass(String(format: "Image survived the round trip (peak %d vs %d source)",
                                result.peak, source.peak))
                } else {
                    fail(String(format: "Round trip lost the image (peak %d vs %d source)",
                                result.peak, source.peak))
                    problems += 1
                }
            }
        }

        if encoded > 0 {
            let rawBytes = Int(preset.pixelWidth) * Int(preset.pixelHeight) * 4
            let averageBytes = bytes / encoded
            note(String(format: "%.1f KB per frame average, down from %.1f MB raw (%.0f:1)",
                        Double(averageBytes) / 1024,
                        Double(rawBytes) / 1_048_576,
                        Double(rawBytes) / Double(max(averageBytes, 1))))
            note(String(format: "encode %.2f ms/frame, decode %.2f ms/frame",
                        Double(encodeTime) / Double(encoded) / 1_000_000,
                        Double(decodeTime) / Double(max(decoded, 1)) / 1_000_000))
            let overhead = Double(wireTotal - bytes) / Double(max(encoded, 1))
            note(String(format: "%.1f KB/s on the wire, %.0f bytes per frame of framing overhead",
                        Double(wireTotal) / max(min(holdSeconds, 8), 1) / 1024, overhead))
            note("Timings are the codec only. Transport and display are still to come.")
        }

        encoder.invalidate()
        decoder.invalidate()
    } catch {
        fail("Could not set up coding: \(error.localizedDescription)")
        problems += 1
    }
}

heading("Streaming over a socket")

if outboundMessages.isEmpty {
    note("Skipped, since no encoded frames were available to send.")
} else {
    let code = PairingCode.random()
    let server = StreamServer(pairingCode: code, serviceName: "Encore Probe")
    let lock = NSLock()

    var serverStarted = false
    var serverError: Error?
    var reentrantCallSurvived = false

    // onClientConnected fires on the server's own queue, and a handler asking
    // "am I connected?" there is the obvious thing to write. It used to trap
    // instantly: dispatch_sync on a queue already owned by the caller. Shipped
    // as a crash, so it gets a check.
    server.onClientConnected = {
        _ = server.isConnected
        lock.lock(); reentrantCallSurvived = true; lock.unlock()
    }

    server.start { error in
        lock.lock(); serverStarted = true; serverError = error; lock.unlock()
    }

    func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() { pump(0.05) }
    }

    waitUntil(5) { lock.lock(); defer { lock.unlock() }; return serverStarted }
    lock.lock(); let startFailure = serverError; let started = serverStarted; lock.unlock()

    if !started || startFailure != nil {
        fail("Host failed to start listening: \(startFailure?.localizedDescription ?? "timed out")")
        problems += 1
    } else if let port = server.port, let endpoint = NWEndpoint.Port(rawValue: port) {
        pass("Host is listening on port \(port)")

        // Discovery, checked separately from the connection below. The frames
        // travel over an explicit loopback address, so without this the Bonjour
        // half would ship untested.
        var discovered: [String] = []
        let finder = StreamClient(pairingCode: code)
        finder.onHostsChanged = { results in
            lock.lock()
            discovered = results.compactMap {
                if case let .service(name, _, _, _) = $0.endpoint { return name }
                return nil
            }
            lock.unlock()
        }
        finder.onError = { _ in }
        finder.browse()
        waitUntil(8) {
            lock.lock(); defer { lock.unlock() }
            return discovered.contains("Encore Probe")
        }
        lock.lock(); let visible = discovered; lock.unlock()
        if visible.contains("Encore Probe") {
            pass("Host discovered over Bonjour by name")
        } else {
            fail("Host never appeared over Bonjour" + (visible.isEmpty ? "" : ", saw \(visible)"))
            problems += 1
        }
        finder.disconnect()

        // --- The paired client. ---
        var connected = false
        var messages: [StreamMessage] = []
        var clientProblem: String?

        let client = StreamClient(pairingCode: code)
        client.onConnected = { lock.lock(); connected = true; lock.unlock() }
        client.onMessage = { message in
            lock.lock(); messages.append(message); lock.unlock()
        }
        client.onError = { error in
            lock.lock()
            if clientProblem == nil { clientProblem = error.localizedDescription }
            lock.unlock()
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: endpoint))

        waitUntil(8) { lock.lock(); defer { lock.unlock() }; return connected }
        lock.lock(); let isConnected = connected; lock.unlock()

        if !isConnected {
            fail("Client never completed the paired handshake")
            problems += 1
        } else {
            pass("Client paired and connected over TLS")

            lock.lock(); let survived = reentrantCallSurvived; lock.unlock()
            if survived {
                pass("Reading server state from the connect callback did not deadlock")
            } else {
                fail("The connect callback never completed, which previously meant a deadlock")
                problems += 1
            }

            lock.lock(); let toSend = outboundMessages; lock.unlock()
            // Paced at roughly the real frame interval. Sending in a tight loop
            // would fill the send queue instantly and trigger the drop policy,
            // which exists for a link that cannot keep up rather than for a
            // sender that refuses to wait.
            for message in toSend {
                server.send(message)
                pump(1.0 / preset.refreshRate)
            }

            waitUntil(8) {
                lock.lock(); defer { lock.unlock() }
                return messages.count >= toSend.count - server.droppedFrames
            }

            lock.lock()
            let arrived = messages
            let failure = clientProblem
            lock.unlock()
            let dropped = server.droppedFrames

            if let failure {
                fail("Client reported: \(failure)")
                problems += 1
            }

            let sentFrames = toSend.filter { if case .frame = $0 { return true } else { return false } }.count
            let arrivedFrames = arrived.filter { if case .frame = $0 { return true } else { return false } }.count

            if arrivedFrames + dropped != sentFrames {
                fail("\(arrivedFrames) arrived plus \(dropped) dropped does not account for "
                     + "\(sentFrames) sent, so frames went missing silently")
                problems += 1
            } else if dropped > 0 {
                // Loopback has no excuse. Drops here mean the send path itself
                // is too slow, not that the network is struggling.
                fail("\(dropped) of \(sentFrames) frames dropped over loopback")
                problems += 1
            } else {
                pass("all \(sentFrames) frames arrived over the socket, none dropped")
            }

            // --- Decode what actually came off the socket. ---
            let socketDecoder = FrameDecoder()
            var socketFormat: CMFormatDescription?
            var decodedOverSocket = 0
            let decodeLock = NSLock()

            for message in arrived {
                switch message {
                case .parameters(let parameters):
                    socketFormat = parameters.makeFormatDescription()
                case .frame(let data, let time, _):
                    guard let socketFormat,
                          let sample = CMSampleBuffer.makeEncodedFrame(
                            data: data, formatDescription: socketFormat, presentationTime: time)
                    else { continue }
                    socketDecoder.decode(sample) { result in
                        if case .success = result {
                            decodeLock.lock(); decodedOverSocket += 1; decodeLock.unlock()
                        }
                    }
                }
            }
            pump(1.0)

            decodeLock.lock(); let decodedCount = decodedOverSocket; decodeLock.unlock()
            if socketFormat == nil {
                fail("Parameter sets never arrived, so the client could not build a decoder")
                problems += 1
            } else if decodedCount > 0 {
                pass("\(decodedCount) frames decoded from bytes received over the socket")
            } else {
                fail("No frames decoded from the socket")
                problems += 1
            }
            socketDecoder.invalidate()

            // --- An unpaired client must be refused. ---
            var intruderConnected = false
            let intruder = StreamClient(pairingCode: PairingCode.random())
            intruder.onConnected = { lock.lock(); intruderConnected = true; lock.unlock() }
            intruder.onError = { _ in }
            intruder.connect(to: .hostPort(host: "127.0.0.1", port: endpoint))
            pump(4.0)

            lock.lock(); let intruderGotIn = intruderConnected; lock.unlock()
            if intruderGotIn {
                fail("A client with the wrong pairing code was allowed to connect")
                problems += 1
            } else {
                pass("A client with the wrong pairing code was refused")
            }
            intruder.disconnect()
        }

        client.disconnect()
    } else {
        fail("Host started but reported no port")
        problems += 1
    }

    server.stop()
}

heading("Tearing down")
let idBeforeTeardown = display.displayID
display.invalidate()
pump(0.5)

if DisplayInfoReader.exists(idBeforeTeardown) {
    fail("Display \(idBeforeTeardown) is still registered after invalidate()")
    problems += 1
} else {
    pass("Display removed cleanly")
}

heading(problems == 0 ? "Result: all checks passed" : "Result: \(problems) problem(s)")
exit(problems == 0 ? 0 : 1)
