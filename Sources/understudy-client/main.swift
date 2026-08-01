import AppKit
import AVFoundation
import CoreMedia
import Foundation
import Network
import UnderstudyKit

// Runs on the spare MacBook. Finds a host on the network, pairs with it, and
// draws the frames it sends fullscreen.
//
//   swift run understudy-client <pairing code>

// Unbuffered: stdout is block-buffered when redirected to anything other
// than a terminal, which would hide progress until the process exits.
setvbuf(stdout, nil, _IONBF, 0)

guard CommandLine.arguments.count > 1 else {
    print("""
    Usage: swift run understudy-client <pairing code>

    Start understudy-host on the Mac you want to extend. It prints a six digit
    code. Pass that code here.
    """)
    exit(1)
}
let pairingCode = CommandLine.arguments[1]

let app = NSApplication.shared
app.setActivationPolicy(.regular)

guard let screen = NSScreen.main else {
    print("No screen to draw on.")
    exit(1)
}

// Fullscreen and borderless normally, since the point is to look like a monitor
// rather than an app. UNDERSTUDY_WINDOWED gives a small ordinary window instead,
// which is the only way to run both ends on one Mac without the client covering
// the host's screen.
let windowed = ProcessInfo.processInfo.environment["UNDERSTUDY_WINDOWED"] != nil
let frame = windowed
    ? NSRect(x: 80, y: 80, width: 800, height: 500)
    : screen.frame

let window = NSWindow(contentRect: frame,
                      styleMask: windowed ? [.titled, .closable, .resizable] : [.borderless],
                      backing: .buffered,
                      defer: false)
if !windowed { window.level = .mainMenu + 1 }
window.title = "Understudy"
window.isOpaque = true
window.backgroundColor = .black
window.setFrame(frame, display: true)

let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
content.wantsLayer = true
content.layer?.backgroundColor = NSColor.black.cgColor

let videoLayer = AVSampleBufferDisplayLayer()
videoLayer.frame = content.bounds
videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
videoLayer.videoGravity = .resizeAspect
videoLayer.backgroundColor = NSColor.black.cgColor
content.layer?.addSublayer(videoLayer)

let status = NSTextField(labelWithString: "Looking for a host on this network...")
status.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
status.textColor = .white
status.frame = NSRect(x: 24, y: 20, width: frame.width - 48, height: 24)
content.addSubview(status)

window.contentView = content
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    // Escape or Q gets you out. A borderless window above the menu bar is
    // otherwise difficult to leave.
    if event.keyCode == 53 || event.charactersIgnoringModifiers?.lowercased() == "q" {
        NSApp.terminate(nil)
    }
    return nil
}

// MARK: - Receiving

let lock = NSLock()
var format: CMFormatDescription?
var framesShown = 0
var lastArrival: CFAbsoluteTime?
/// Gaps between arriving frames. On Wi-Fi the spread of these matters far more
/// than the average: a steady 30 ms reads as a monitor, a mean of 20 ms with
/// regular 120 ms spikes reads as broken.
var gaps: [Double] = []

/// Tells the layer to present as soon as the frame decodes, rather than holding
/// it against a timebase. For a live screen, late is worse than uneven.
func markDisplayImmediately(_ sample: CMSampleBuffer) {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
          CFArrayGetCount(attachments) > 0 else { return }
    let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
    CFDictionarySetValue(entry,
                         Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                         Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
}

let client = StreamClient(pairingCode: pairingCode)

client.onMessage = { message in
    switch message {
    case .parameters(let parameters):
        guard let rebuilt = parameters.makeFormatDescription() else { return }
        lock.lock(); format = rebuilt; lock.unlock()

    case .frame(let data, let time, _):
        lock.lock()
        let current = format
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastArrival { gaps.append((now - last) * 1000) }
        lastArrival = now
        lock.unlock()

        guard let current,
              let sample = CMSampleBuffer.makeEncodedFrame(
                data: data, formatDescription: current, presentationTime: time)
        else { return }
        markDisplayImmediately(sample)

        DispatchQueue.main.async {
            if videoLayer.status == .failed { videoLayer.flush() }
            videoLayer.enqueue(sample)
            lock.lock(); framesShown += 1; lock.unlock()
            if status.isHidden == false { status.isHidden = true }
        }
    }
}

client.onConnected = {
    DispatchQueue.main.async { status.stringValue = "Connected. Waiting for frames..." }
}

client.onDisconnected = { error in
    DispatchQueue.main.async {
        status.isHidden = false
        status.stringValue = error.map { "Disconnected: \($0.localizedDescription)" } ?? "Disconnected."
        videoLayer.flush()
        lock.lock(); format = nil; lock.unlock()
    }
}

client.onError = { error in
    DispatchQueue.main.async {
        status.isHidden = false
        status.stringValue = "Error: \(error.localizedDescription)"
    }
}

// Connect to the first host that appears. With one host on the network this is
// what anyone would pick anyway; a chooser belongs in the real app.
var connecting = false
client.onHostsChanged = { results in
    guard !connecting, let first = results.first else { return }
    connecting = true
    let name: String
    if case let .service(serviceName, _, _, _) = first.endpoint { name = serviceName } else { name = "host" }
    DispatchQueue.main.async { status.stringValue = "Found \(name). Pairing..." }
    client.connect(to: first.endpoint)
}
client.browse()

// MARK: - Reporting

// Printed to the terminal rather than drawn on screen, so the picture stays a
// clean representation of the host's display.
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    lock.lock()
    let shown = framesShown
    let measured = gaps.sorted()
    gaps.removeAll()
    lock.unlock()

    guard !measured.isEmpty else { return }

    // Gaps longer than this are the screen having nothing new to show, not the
    // network being slow. Mixing them into a jitter figure makes an idle desktop
    // look like a broken connection, which is the opposite of the truth.
    let active = measured.filter { $0 < 100 }
    let idlePauses = measured.count - active.count

    guard !active.isEmpty else {
        print(String(format: "  idle, nothing changing on screen   (%d frames shown)", shown))
        return
    }

    let mean = active.reduce(0, +) / Double(active.count)
    let median = active[active.count / 2]
    let p95 = active[min(active.count - 1, Int(Double(active.count) * 0.95))]
    print(String(format: "  %5.1f fps while active   gap: median %.1f ms, p95 %.1f ms, worst %.1f ms"
                       + "   %d idle pauses   (%d frames shown)",
                 1000 / max(mean, 0.001), median, p95, active.last ?? 0, idlePauses, shown))
}

app.run()
