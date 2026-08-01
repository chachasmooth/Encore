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
        .windowResizability(.contentSize)
    }
}

/// Chosen once per launch and never changed back. macOS only allows one virtual
/// display per process, so a host that stopped and restarted would fail to get a
/// second one, and the simplest fix is not to offer the path.
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

            Text("Run this app on both Macs and pick one option on each.")
                .font(.callout)
                .foregroundStyle(.tertiary)
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
    @State private var session: HostSession?
    @State private var problem: String?
    @State private var connected = false
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
                    Text("Drag a window off the edge of this screen to send it across.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Which MacBook is the second screen?").font(.title2)
                Picker("", selection: $preset) {
                    ForEach(DisplayPreset.all, id: \.name) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .frame(width: 320)

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

    private func stat(_ value: String, _ label: String) -> some View {
        VStack {
            Text(value).font(.system(size: 22, weight: .medium, design: .monospaced))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 90)
    }

    private func start() {
        problem = nil
        let session = HostSession(preset: preset)
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
    private let layer = AVSampleBufferDisplayLayer()

    var body: some View {
        ZStack {
            if showingVideo {
                VideoLayerView(layer: layer).ignoresSafeArea()
            } else {
                VStack(spacing: 20) {
                    Text("Enter the code from your other Mac").font(.title2)
                    TextField("000000", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 34, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 220)
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
                .frame(width: 520)
            }
        }
    }

    private func connect() {
        guard code.count == 6, session == nil else { return }
        let session = ClientSession(pairingCode: code)
        session.onStatus = { text in DispatchQueue.main.async { statusText = text } }
        session.onDisconnected = { _ in
            DispatchQueue.main.async {
                showingVideo = false
                statusText = "Disconnected."
                layer.flush()
                self.session = nil
            }
        }
        session.onFrame = { sample in
            markDisplayImmediately(sample)
            DispatchQueue.main.async {
                if layer.status == .failed { layer.flush() }
                layer.enqueue(sample)
                if !showingVideo {
                    showingVideo = true
                    // Only once frames are actually arriving, so a failed pairing
                    // never leaves someone stuck on a black fullscreen window.
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
            }
        }
        session.start()
        self.session = session
    }
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
