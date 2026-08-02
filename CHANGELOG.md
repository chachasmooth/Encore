# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-08-02

First working version. A spare MacBook can be used as a second display, verified
across two Macs over Wi-Fi, with windows dragged onto it and staying there.

### Added

- `USVirtualDisplay` creates a virtual monitor that macOS treats as real
  hardware, via private CoreGraphics API. Verified producing a Retina display of
  1512×982 points backed by 3024×1964 pixels on macOS 26.5.
- `VirtualDisplay` and `DisplayPreset`, a Swift API with presets matching the
  native geometry of recent MacBook panels.
- `DisplayInfoReader` reads display geometry across three CoreGraphics and
  AppKit APIs, each of which is unreliable in a different way.
- `understudy-probe` is a diagnostic CLI that creates a display, verifies macOS
  registered it at the requested geometry, and confirms clean teardown.
- `Tools/dump-private-api.m` prints live signatures of Apple's private classes,
  for checking after macOS updates.
- Project documentation, CI, and contribution guidelines.

- `DisplayCapture` pulls frames off a display with ScreenCaptureKit. Verified
  delivering 3024×1964 BGRA frames from the virtual display on macOS 26.5.
  Frames carrying no new content are counted rather than delivered, since a
  static desktop would otherwise be re-encoded for nothing.
- `ScreenRecordingPermission` checks and requests the permission ScreenCaptureKit
  needs. Without it macOS still returns correctly sized frames that are entirely
  black, so the probe tests peak pixel value rather than average brightness and
  writes the first frame to a PNG for inspection.

- `FrameEncoder` and `FrameDecoder` wrap VideoToolbox HEVC. Verified round
  tripping captured frames at 3024×1964 with the image intact: encode 10 to
  13 ms per frame on hardware, decode about 5 ms.

- `StreamProtocol` serialises encoded frames for the network: HEVC parameter set
  extraction and rebuilding, length-prefixed message framing, and reconstruction
  of a decodable frame from received bytes. In-process the decoder gets the
  stream's parameter sets for free from the encoder; across a socket they have to
  travel explicitly or the client cannot build a decoder at all. The probe now
  pushes every frame through this byte format before decoding, so the wire path
  is exercised without a socket involved.

- `StreamServer` and `StreamClient` carry frames over the network: Bonjour
  discovery, TLS pairing from a six digit code, length-prefixed messages, and a
  bounded send queue that drops stale frames rather than letting them queue into
  latency. `FrameEncoder.encode` gained a `forceKeyframe` flag, since dropping a
  frame breaks HEVC's reference chain until a self-contained frame arrives.
  Verified over loopback: discovery by name, paired handshake, 39 of 39 frames
  delivered and decoded, and a client with the wrong code refused.

- `Understudy.app`: both roles in one bundle, chosen on launch, with the pairing
  code shown on screen instead of in a terminal. `Tools/build-app.sh` produces it
  with Command Line Tools alone; Xcode turned out not to be required. Signing is
  ad-hoc, which gives the app its own identity for permissions but leaves
  Gatekeeper needing the quarantine flag cleared by hand.
- `HostSession` and `ClientSession` hold the host and client pipelines, so
  everything runs one implementation.

### Fixed

- The client rendered black while reporting healthy. Its video layer was zero by
  zero pixels for the life of the window, because `VideoLayerView` replaced the
  view's backing layer after the view was already layer-backed, and set the
  layer's frame only from SwiftUI's update pass, which does not run when AppKit
  resizes the window for fullscreen. A zero-sized `AVSampleBufferDisplayLayer`
  accepts frames, decodes them, and reports itself as rendering while drawing
  nothing, so every number on screen was healthy and true. The layer now gets an
  explicit frame and an autoresizing mask, verified tracking resizes from
  900×418 to 1440×868 to 700×368.
- The client counts keyframes separately and decodes its first one to a PNG in
  `~/Library/Logs/Understudy`, since a stream with frames but no keyframes cannot
  be decoded at all and looks identical to a healthy one by frame count.
- The virtual display had no wallpaper, so an empty second screen was pure black
  apart from the menu bar and read as a failed connection.
- The client never entered fullscreen on connect. Two causes: the window accessor
  was missing, and `.windowResizability(.contentSize)` drops `.resizable`, which
  makes `toggleFullScreen` a silent no-op.
- A crash on client connect, from `dispatch_sync` onto a queue the calling thread
  already owned.
- A leaked virtual display when the server failed to start, which held the
  machine's only slot.
- The `macBookAir13` preset described the 13.6-inch M2 Air (2560×1664) while
  being named for the 13-inch. The 13.3-inch Air, including the M1, is 2560×1600.
  Presets are now the five distinct panel resolutions across every MacBook from
  the M1 to the M5, checked against Apple's published specifications rather than
  memory. Streaming the wrong one means the wrong aspect ratio and a rescale on
  every frame.

### Changed

- Licensed under GPL-3.0 instead of MIT, so modified versions distributed to
  others have to stay open source.

### Known limitations

- Only one virtual display can exist at a time on the machine, not one per
  process as first thought. A leaked display blocks every other process from
  creating one.
- DRM-protected content will capture as black frames. Not fixable.
- Relies on private Apple API, so a macOS update can break it. Detected and
  reported as a clear error rather than a crash.

[Unreleased]: https://github.com/chachasmooth/Understudy/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/chachasmooth/Understudy/releases/tag/v0.2.0
