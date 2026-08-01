<div align="center">

# Understudy

**Turn a spare MacBook into a second display for your Mac.**

[![CI](https://github.com/chachasmooth/Understudy/actions/workflows/ci.yml/badge.svg)](https://github.com/chachasmooth/Understudy/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](#requirements)
[![Status](https://img.shields.io/badge/status-early%20development-orange.svg)](#status)

</div>

---

## Status

Early development. You cannot use this as a monitor yet.

The whole pipeline works and has run across two Macs over Wi-Fi: an M5 MacBook Air streaming to an M1 Air, 47 to 49 fps with no dropped frames, peaking at 51 Mb/s while a window was dragged around. It is still two command-line tools rather than an app you can double-click.

| Milestone | State |
|---|---|
| **1. Virtual display** | Working, verified on macOS 26.5 |
| **2. Capture frames off that display** | Working, verified on macOS 26.5 |
| **3. Encode and decode as HEVC** | Working, verified on macOS 26.5 |
| **4. Send frames over the network** | Working, verified across two Macs |
| **5. Client that displays them fullscreen** | Working, verified across two Macs |
| 6. One download, pick a role, done | Not started |

Star the repo if you want to hear when it works end to end.

## What it will do

Open Understudy on both Macs, pair them with a six digit code, and the spare one becomes a second display for the main one. Drag windows onto it, park your reference docs there, extend your desktop the way you would with any monitor.

macOS treats it as attached hardware. The cursor crosses onto it. Windows remember where they were. It appears in System Settings alongside anything else you have plugged in.

## What it won't do

Apple provides no supported way to turn one Mac into a display for another. Sidecar covers iPads and stops there. Understudy fills that gap with private system API, which carries real costs. See [Caveats](#caveats).

Protected video will not show up. Netflix, Apple TV+ and anything else using DRM will render as a black rectangle. macOS blocks screen capture of protected content at a level no application can reach around.

It will also never appear on the Mac App Store. Private API disqualifies it.

## Requirements

- Two Apple Silicon MacBooks, M1 or newer, running macOS 14 (Sonoma) or later
- Both on the same Wi-Fi network
- Screen Recording permission on the host Mac

No cable. Every M-series MacBook has hardware HEVC encoding and decoding, which is why the requirement is drawn there. Intel Macs are untested.

A compressed stream needs a few Mb/s, which any modern Wi-Fi handles comfortably, so bandwidth is not the constraint. Consistency is. Wi-Fi's problem is not its average latency but its occasional spikes, and a display that is reliably 30 ms behind feels far better than one that is usually 20 ms and jumps to 120 ms. Understudy drops stale frames rather than queueing them for exactly this reason.

A Thunderbolt cable or a pair of USB-C Ethernet adapters will both be faster and steadier, and they work with no extra setup because the transport is ordinary TCP over whichever interface exists. Neither is required.

Understudy pairs with a six digit code shown on the host. That code becomes the TLS pre-shared key for the connection, so a machine that does not have it cannot complete the handshake and never receives a frame.

### Supported panels

The spare MacBook gets a virtual display matching its own screen exactly, so nothing is rescaled.

| Model | Native | Sent as |
|---|---|---|
| Air 13.3-inch (M1), Pro 13.3-inch (M1, M2) | 2560×1600 | 1280×800 at 2x |
| Air 13.6-inch (M2 onwards) | 2560×1664 | 1280×832 at 2x |
| Air 15.3-inch (M2 onwards) | 2880×1864 | 1440×932 at 2x |
| Pro 14.2-inch (M1 Pro onwards) | 3024×1964 | 1512×982 at 2x |
| Pro 16.2-inch (M1 Pro onwards) | 3456×2234 | 1728×1117 at 2x |

Six models, five resolutions, and Apple has not changed any of them between the M1 and the M5.

## How it works

```
        HOST MAC                                   CLIENT MAC
   (the one being extended)                     (the spare laptop)

  ┌─────────────────────────┐                ┌─────────────────────┐
  │  Virtual display        │                │                     │
  │  macOS sees a monitor   │                │                     │
  │  that does not exist    │                │                     │
  └───────────┬─────────────┘                │                     │
              │ frames                       │                     │
  ┌───────────▼─────────────┐                │                     │
  │  ScreenCaptureKit       │                │                     │
  │  capture that display   │                │                     │
  └───────────┬─────────────┘                │                     │
              │ CVPixelBuffer                │                     │
  ┌───────────▼─────────────┐                ┌─────────▼───────────┐
  │  VideoToolbox           │                │  VideoToolbox       │
  │  hardware HEVC encode   │                │  hardware decode    │
  └───────────┬─────────────┘                └─────────┬───────────┘
              │                                        │
              └────────────── Wi-Fi ───────────────────┘
                    paired, TLS, stale frames dropped
```

Step one carries all the risk. macOS exposes no public way to register a virtual monitor, so Understudy calls four undocumented CoreGraphics classes. Every one of those calls lives in [a single file](Sources/CVirtualDisplay/USVirtualDisplay.m). When Apple eventually changes something, one small well-marked place breaks instead of the whole application.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) covers the details, including three display APIs that each fail in a different way and cost a lot of debugging time.

## Building

macOS 14 or newer, plus Xcode Command Line Tools.

```bash
git clone https://github.com/chachasmooth/Understudy.git
```

```bash
cd Understudy && swift build
```

## Using it

Two command-line tools for now. On the Mac you want to extend:

```bash
swift run understudy-host 13
```

The number is the size of the spare MacBook's screen: `13`, `13.6`, `15`, `14` or `16`. It prints a six digit pairing code.

Then on the spare MacBook, with the repository cloned there too:

```bash
swift run understudy-client 123456
```

It finds the host on the network, pairs, and fills the screen. Escape or Q quits.

Set `UNDERSTUDY_WINDOWED=1` to run the client in an ordinary window instead of fullscreen, which is the only sane way to test both halves on a single Mac.

### Trying it

The probe exercises everything built so far on a single machine: it creates the display, captures it, encodes and decodes, then streams real frames to a client over a socket on loopback.

```bash
swift run understudy-probe 20
```

```
  ✓ Backing resolution matches: 2560×1600 px
  ✓ Retina/HiDPI confirmed (2.0x scale)
  ✓ Frames are arriving
  ✓ Frames contain real pixels (peak 153, mean 0.0018)
  ✓ Encoder is hardware accelerated
  ✓ 50 frames survived the wire format intact
  ✓ Image survived the round trip (peak 158 vs 153 source)
  ✓ Host discovered over Bonjour by name
  ✓ Client paired and connected over TLS
  ✓ all 39 frames arrived over the socket, none dropped
  ✓ 39 frames decoded from bytes received over the socket
  ✓ A client with the wrong pairing code was refused
```

The first captured frame is saved as a PNG and the probe prints its path, so you can open it and see exactly what came back.

Two things surprise people here. A freshly created display has no wallpaper on it, so that PNG is mostly black with only a menu bar across the top, and that is correct rather than broken. An idle screen also produces very few frames with new content, because ScreenCaptureKit sends one only when something actually changes.

Open System Settings > Displays while it runs and you will find a second monitor listed. Windows dragged onto it vanish from view, since nothing draws them on a second screen yet.

## Caveats

Understudy depends on private Apple API. No public alternative exists, and every application in this category makes the same compromise. What that means in practice:

A macOS update can break it. Understudy checks that the classes and methods it needs are still present and reports a clear error if they are not, so you get an explanation rather than a crash. It still stops working until somebody updates it.

Builds you hand to other people need a paid Apple Developer certificate and notarization. Without those, Gatekeeper refuses to open the app.

One more limitation, this one unexplained so far: a process can create a single virtual display. Releasing it and creating another in the same process fails, and the second display never registers. That needs solving before Understudy can drive more than one spare MacBook.

## Roadmap

- [x] Create a Retina virtual display and confirm macOS accepts it
- [x] Capture the virtual display with ScreenCaptureKit
- [x] Hardware HEVC encode and decode, tuned for latency ahead of quality
- [x] Wi-Fi transport with Bonjour discovery and paired TLS
- [x] Client rendering the stream fullscreen
- [x] Verify across two machines over real Wi-Fi
- [ ] Measure true glass-to-glass latency
- [ ] Pairing, so the two Macs find each other without configuration
- [ ] Single app bundle with a host and client role picker
- [ ] Signed, notarized releases
- [ ] Wireless transport
- [ ] More than one client Mac

Out of scope for now: driving the host from the spare Mac's keyboard and trackpad, iPad support, and clients on Windows or Linux.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Compatibility reports are useful even when everything works, since the private API this relies on can shift between macOS releases and there is no way to know without people running it.

## License

[GPL-3.0](LICENSE).

Use it, change it, share it. If you distribute a modified version, you have to
release your changes under the same licence. That keeps Understudy open, and
stops anyone shipping a closed commercial fork of it.

Copyright (C) 2026 chachasmooth
