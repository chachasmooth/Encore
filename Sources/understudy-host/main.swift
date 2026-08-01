import AppKit
import CoreMedia
import CoreVideo
import Foundation
import UnderstudyKit

// Runs on the Mac being extended. Creates a virtual display, captures it,
// encodes it, and streams it to whichever client pairs with the printed code.
//
//   swift run understudy-host [13 | 13.6 | 15 | 14 | 16]

// Unbuffered: stdout is block-buffered when redirected to anything other
// than a terminal, which would hide progress until the process exits.
setvbuf(stdout, nil, _IONBF, 0)

let presetsByName: [String: DisplayPreset] = [
    "13": .macBook13, "13.6": .macBookAir13_6, "15": .macBookAir15,
    "14": .macBookPro14, "16": .macBookPro16,
]

let requested = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "13"
guard let preset = presetsByName[requested] else {
    print("Unknown screen size '\(requested)'. Use one of: \(presetsByName.keys.sorted().joined(separator: ", "))")
    print("Pick the size of the MacBook you want to use as the second screen.")
    exit(1)
}

func fail(_ message: String) -> Never {
    print("\u{001B}[31m\(message)\u{001B}[0m")
    exit(1)
}

guard USVirtualDisplay.isSupported else {
    fail("This version of macOS does not provide the virtual display API Understudy needs.")
}
guard ScreenRecordingPermission.isGranted else {
    ScreenRecordingPermission.request()
    fail("""
    Screen Recording permission is required.
    Grant it in System Settings > Privacy & Security > Screen Recording, then run this again.
    """)
}

let display: VirtualDisplay
do {
    display = try VirtualDisplay(preset: preset, name: "Understudy")
} catch {
    fail("Could not create the virtual display: \(error.localizedDescription)")
}

let encoder: FrameEncoder
do {
    encoder = try FrameEncoder(pixelWidth: Int(preset.pixelWidth),
                               pixelHeight: Int(preset.pixelHeight),
                               frameRate: Int(preset.refreshRate))
} catch {
    fail("Could not start the encoder: \(error.localizedDescription)")
}

let code = PairingCode.random()
let serviceName = Host.current().localizedName ?? "Understudy Host"
let server = StreamServer(pairingCode: code, serviceName: serviceName)
let capture = DisplayCapture(displayID: display.displayID,
                             pixelWidth: Int(preset.pixelWidth),
                             pixelHeight: Int(preset.pixelHeight),
                             frameRate: Int(preset.refreshRate))

let state = NSLock()
var parametersSent = false
var needsKeyframe = false
var frameIndex: Int64 = 0
var sentFrames = 0
var sentBytes = 0

// A dropped frame breaks HEVC's reference chain, so the next frame has to be
// self-contained or the client shows corruption until the next scheduled keyframe.
server.onFrameDropped = {
    state.lock(); needsKeyframe = true; state.unlock()
}

server.onClientConnected = {
    // The new client has no parameter sets and no keyframe, so it cannot decode
    // anything that references earlier frames. Start it from scratch.
    state.lock(); parametersSent = false; needsKeyframe = true; state.unlock()
    print("\n\u{001B}[32m✓ Client connected.\u{001B}[0m Streaming \(preset.name).")
}

server.onClientDisconnected = { error in
    if let error {
        print("\n\u{001B}[33mClient disconnected: \(error.localizedDescription)\u{001B}[0m")
    } else {
        print("\n\u{001B}[33mClient disconnected.\u{001B}[0m")
    }
    print("Waiting for a client. Pairing code: \u{001B}[1m\(code)\u{001B}[0m")
}

server.start { error in
    if let error { fail("Could not start listening: \(error.localizedDescription)") }
}

capture.start(onFrame: { buffer in
    guard server.isConnected else { return }

    state.lock()
    let time = CMTime(value: frameIndex, timescale: CMTimeScale(preset.refreshRate))
    frameIndex += 1
    let forceKeyframe = needsKeyframe
    needsKeyframe = false
    state.unlock()

    encoder.encode(buffer, at: time, forceKeyframe: forceKeyframe) { result in
        guard case .success(let sample) = result,
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

        state.lock(); sentFrames += 1; sentBytes += payload.count; state.unlock()
    }
}, completion: { error in
    if let error { fail("Could not start capturing: \(error.localizedDescription)") }
})

print("""

\u{001B}[1mUnderstudy host\u{001B}[0m
Second screen: \(preset.name), \(preset.pixelWidth)×\(preset.pixelHeight)
Advertising as "\(serviceName)" on this network.

On the spare MacBook, run:
  \u{001B}[1mswift run understudy-client \(code)\u{001B}[0m

Pairing code: \u{001B}[1m\(code)\u{001B}[0m
Press Ctrl-C to stop.
""")

// Report throughput once a second. On Wi-Fi the bitrate matters, and it is the
// number most likely to differ from what loopback suggested.
var lastReport = Date()
var lastFrames = 0
var lastBytes = 0

while true {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    guard Date().timeIntervalSince(lastReport) >= 1 else { continue }

    state.lock()
    let frames = sentFrames, bytes = sentBytes
    state.unlock()

    let elapsed = Date().timeIntervalSince(lastReport)
    let fps = Double(frames - lastFrames) / elapsed
    let mbps = Double(bytes - lastBytes) * 8 / elapsed / 1_000_000
    lastReport = Date()
    lastFrames = frames
    lastBytes = bytes

    if server.isConnected {
        print(String(format: "\r  %5.1f fps out  %6.2f Mb/s  %d dropped   ",
                     fps, mbps, server.droppedFrames), terminator: "")
        fflush(stdout)
    }
}
