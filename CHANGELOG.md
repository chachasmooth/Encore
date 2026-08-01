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
