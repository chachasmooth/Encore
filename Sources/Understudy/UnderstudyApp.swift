import AVFoundation
import AppKit
import SwiftUI
import UnderstudyKit

@main
struct UnderstudyApp: App {
    var body: some Scene {
        WindowGroup("Understudy") {
            RootView()
        }
        // Deliberately not .contentSize: that drops .resizable from the window's
        // style mask, and toggleFullScreen silently does nothing without it.
        .windowResizability(.automatic)
    }
}

extension Bundle {
    /// Version from Info.plist, or a clear marker when running unbundled.
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
    }
}

/// Chosen once per launch and never changed back. Only one virtual display can
/// exist on the machine at a time, so a host that stopped and restarted would
/// fail to get another, and the simplest fix is not to offer the path.
enum Role {
    case undecided, host, client
}

struct RootView: View {
    @State private var role = Role.undecided

    var body: some View {
        switch role {
        case .undecided: RolePicker(role: $role)
        case .host: HostView()
        case .client: ClientView()
        }
    }
}

struct RolePicker: View {
    @Binding var role: Role

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("Understudy").font(.system(size: 34, weight: .semibold))
                Text("Use a spare MacBook as a second display")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                choice(title: "Extend this Mac",
                       detail: "Adds a second screen here, shown on your other MacBook.",
                       symbol: "rectangle.on.rectangle") { role = .host }

                choice(title: "Be the second screen",
                       detail: "This MacBook becomes a display for another Mac.",
                       symbol: "display") { role = .client }
            }

            VStack(spacing: 4) {
                Text("Run this app on both Macs and pick one option on each.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                // Shown because both machines must run the same build, and a
                // mismatch is otherwise invisible and produces baffling symptoms.
                Text("Version \(Bundle.main.appVersion)")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                    .textSelection(.enabled)
            }
        }
        .padding(40)
        .frame(width: 640)
    }

    private func choice(title: String, detail: String, symbol: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 34))
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    // Without an explicit width the text stays on one line and
                    // truncates rather than wrapping inside the card.
                    .frame(width: 200)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 240, height: 160)
            .padding(12)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Host

struct HostView: View {
    @State private var preset = DisplayPreset.macBook13
    @AppStorage("screenPosition") private var positionRaw = ScreenPosition.right.rawValue
    @State private var session: HostSession?
    @State private var problem: String?
    @State private var connected = false
    @State private var stopped = false
    @State private var fps = 0.0
    @State private var mbps = 0.0
    @State private var lastFrames = 0
    @State private var lastBytes = 0

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            if let session {
                Text(connected ? "Connected" : "Waiting for your other MacBook")
                    .font(.title2)

                VStack(spacing: 4) {
                    Text("Pairing code").font(.caption).foregroundStyle(.secondary)
                    Text(session.pairingCode)
                        .font(.system(size: 46, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                }

                Text("On the other MacBook, open Understudy, choose \"Be the second screen\", and enter this code.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                if connected {
                    HStack(spacing: 18) {
                        stat(String(format: "%.0f", fps), "frames/sec")
                        stat(String(format: "%.1f", mbps), "Mb/s")
                        stat("\(session.droppedFrames)", "dropped")
                    }
                    Text("Drag a window off the \(ScreenPosition(rawValue: positionRaw)?.edgeName ?? "right") edge of this screen to send it across.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                positionPicker

                Button("Stop", role: .destructive) { stop() }
                    .controlSize(.large)
            } else if stopped {
                Text("Stopped").font(.title2)
                Text("The second screen has been removed. Only one virtual display can exist at a time, so starting again needs Understudy relaunched.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Quit Understudy") { NSApp.terminate(nil) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Text("Which MacBook is the second screen?").font(.title2)
                Picker("", selection: $preset) {
                    ForEach(DisplayPreset.all, id: \.name) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .frame(width: 320)

                positionPicker

                Button("Start") { start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
        .padding(40)
        .frame(width: 560)
        .onReceive(tick) { _ in refresh() }
    }

    /// Shown both before starting and while streaming, since moving the second
    /// screen is exactly the sort of thing you work out you want once you can
    /// see it.
    private var positionPicker: some View {
        VStack(spacing: 6) {
            Text("Which side of this screen?").font(.callout).foregroundStyle(.secondary)
            Picker("", selection: $positionRaw) {
                ForEach(ScreenPosition.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)
            .onChange(of: positionRaw) { _, raw in
                if let position = ScreenPosition(rawValue: raw) { session?.move(to: position) }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack {
            Text(value).font(.system(size: 22, weight: .medium, design: .monospaced))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 90)
    }

    private func start() {
        problem = nil
        let session = HostSession(preset: preset,
                                  position: ScreenPosition(rawValue: positionRaw) ?? .right)
        session.onClientConnected = { DispatchQueue.main.async { connected = true } }
        session.onClientDisconnected = { _ in DispatchQueue.main.async { connected = false } }
        session.start { error in
            DispatchQueue.main.async {
                if let error {
                    problem = error.localizedDescription
                    self.session = nil
                } else {
                    self.session = session
                }
            }
        }
        self.session = session
    }

    private func stop() {
        session?.stop()
        session = nil
        connected = false
        stopped = true
    }

    private func refresh() {
        guard let session else { return }
        let frames = session.framesSent, bytes = session.bytesSent
        fps = Double(frames - lastFrames)
        mbps = Double(bytes - lastBytes) * 8 / 1_000_000
        lastFrames = frames
        lastBytes = bytes
    }
}

// MARK: - Client

struct ClientView: View {
    @State private var code = ""
    @State private var session: ClientSession?
    @State private var statusText = ""
    @State private var showingVideo = false
    /// A reference type on purpose. Escaping callbacks capture the View struct
    /// as it was when they were created, so a plain @State NSWindow? read back
    /// inside one is whatever it held then, which is nil.
    @State private var windowBox = WindowBox()
    @State private var diagnostics = "waiting for first frame"
    @State private var inspection = "no keyframe yet"
    @State private var lastFrameAt: Date?
    @State private var framesShown = 0
    private let layer = AVSampleBufferDisplayLayer()
    private let diagnosticTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if showingVideo {
                VideoLayerView(layer: layer).ignoresSafeArea()
                // Deliberately visible over the picture. A blank second screen
                // has several possible causes and they are indistinguishable by
                // eye: nothing arriving, arriving but not decoding, or a genuinely
                // empty desktop. This says which.
                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(diagnostics)
                            Text(inspection)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.55)))
                        .padding(10)
                        Spacer()
                    }
                    Spacer()
                }
            } else {
                VStack(spacing: 20) {
                    Text("Enter the code from your other Mac").font(.title2)
                    TextField("000000", text: $code)
                        // Plain style with an explicit height, because a bordered
                        // field sizes itself for body text and clips large digits.
                        .textFieldStyle(.plain)
                        .font(.system(size: 30, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 200, height: 48)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(Color.primary.opacity(0.1)))
                        .onChange(of: code) { _, new in
                            // Codes are always six digits, so anything else is a
                            // typo worth swallowing rather than overflowing with.
                            let digits = new.filter(\.isNumber)
                            if digits != new || digits.count > 6 {
                                code = String(digits.prefix(6))
                            }
                        }
                        .onSubmit(connect)
                    Button("Connect", action: connect)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(code.count != 6 || session != nil)
                    if !statusText.isEmpty {
                        Text(statusText).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 320)
        .onReceive(diagnosticTick) { _ in
            guard showingVideo else { return }
            let since = lastFrameAt.map { String(format: "%.1fs ago", Date().timeIntervalSince($0)) } ?? "never"
            let status: String
            switch layer.status {
            case .failed: status = "layer FAILED"
            case .rendering: status = "rendering"
            default: status = "idle"
            }
            let keyframes = session?.keyframesReceived ?? 0
            diagnostics = "frames \(framesShown)   keyframes \(keyframes)   last \(since)   \(status)"
        }
        .background(WindowAccessor { window in
            windowBox.window = window
            // Belt and braces: fullscreen is refused outright on a window that
            // is not resizable, and it fails quietly.
            window.styleMask.insert(.resizable)
            window.collectionBehavior.insert(.fullScreenPrimary)
        })
    }

    private func connect() {
        guard code.count == 6, session == nil else { return }
        let session = ClientSession(pairingCode: code)
        session.onStatus = { text in DispatchQueue.main.async { statusText = text } }
        session.onFirstKeyframeInspected = { summary in
            DispatchQueue.main.async { inspection = summary }
        }

        session.onConnected = {
            DispatchQueue.main.async {
                showingVideo = true
                setFullScreen(windowBox.window, true)
            }
        }

        session.onDisconnected = { _ in
            DispatchQueue.main.async {
                // Leave fullscreen before anything else, or the window is left
                // as a black fullscreen shell with no way back to the code entry.
                showingVideo = false
                statusText = "The other Mac stopped sharing."
                layer.flush()
                self.session = nil
                leaveFullScreenAndResize(windowBox.window)
            }
        }

        session.onFrame = { sample in
            markDisplayImmediately(sample)
            DispatchQueue.main.async {
                if layer.status == .failed {
                    layer.flush()
                    // The flushed decoder cannot use a delta frame, so wait for
                    // the next keyframe rather than failing again immediately.
                    session.resyncAfterFlush()
                }
                layer.enqueue(sample)
                framesShown += 1
                lastFrameAt = Date()
            }
        }
        session.start()
        self.session = session
    }
}

/// Holds the window by reference, so callbacks read the current one rather than
/// whatever the View struct held when they were created.
final class WindowBox {
    var window: NSWindow?
}

/// Hands back the real NSWindow behind a SwiftUI view.
///
/// Guessing at it with `NSApp.windows.first(where: \.isVisible)` picked up
/// whichever window AppKit happened to list first, which is why fullscreen
/// silently did nothing.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
    }
}

/// Leaves fullscreen and puts the window back to a sensible size.
///
/// Exiting fullscreen keeps the old frame, so the code-entry panel ends up
/// stranded in the corner of a full-screen black window. The resize waits for
/// the exit animation, since setting a frame mid-transition is ignored.
private func leaveFullScreenAndResize(_ window: NSWindow?) {
    guard let window else { return }
    guard window.styleMask.contains(.fullScreen) else { return window.center() }

    // Held in a box so the observer can unregister itself without the closure
    // capturing a var it also assigns.
    final class TokenBox { var value: NSObjectProtocol? }
    let box = TokenBox()
    box.value = NotificationCenter.default.addObserver(
        forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
            window.setContentSize(NSSize(width: 560, height: 340))
            window.center()
            if let value = box.value { NotificationCenter.default.removeObserver(value) }
        }
    window.toggleFullScreen(nil)
}

/// AppKit only offers a toggle, so calling it blindly does the opposite of what
/// was asked half the time.
private func setFullScreen(_ window: NSWindow?, _ wanted: Bool) {
    guard let window, window.styleMask.contains(.fullScreen) != wanted else { return }
    window.toggleFullScreen(nil)
}

/// Present as soon as the frame decodes rather than scheduling it against a
/// timebase. For a live screen, late is worse than uneven.
private func markDisplayImmediately(_ sample: CMSampleBuffer) {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
          CFArrayGetCount(attachments) > 0 else { return }
    let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
    CFDictionarySetValue(entry,
                         Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                         Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
}

struct VideoLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        layer.videoGravity = .resizeAspect
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        layer.frame = view.bounds
    }
}
