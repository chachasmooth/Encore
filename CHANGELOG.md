# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Understudy cannot yet be used as a display. This entry covers foundational work.

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

### Fixed

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

- Only one virtual display per process. Creating a second after releasing the
  first fails to register.
- DRM-protected content will capture as black frames. Not fixable.
- Relies on private Apple API, so a macOS update can break it. Detected and
  reported as a clear error rather than a crash.

[Unreleased]: https://github.com/chachasmooth/Understudy/commits/main
