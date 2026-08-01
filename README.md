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

The virtual display works and frames come off it. Nothing is sent anywhere yet.

| Milestone | State |
|---|---|
| **1. Virtual display** | Working, verified on macOS 26.5 |
| **2. Capture frames off that display** | Working, verified on macOS 26.5 |
| **3. Encode and decode as HEVC** | Working, verified on macOS 26.5 |
| 4. Send frames to the other Mac over a cable | Not started |
| 5. Client app that displays them fullscreen | Not started |
| 6. One download, pick a role, done | Not started |

Star the repo if you want to hear when it works end to end.

## What it will do

Connect two Macs with a USB-C cable. The spare one becomes a second display for the main one. Drag windows onto it, park your reference docs there, extend your desktop the way you would with any monitor.

macOS treats it as attached hardware. The cursor crosses onto it. Windows remember where they were. It appears in System Settings alongside anything else you have plugged in.

## What it won't do

Apple provides no supported way to turn one Mac into a display for another. Sidecar covers iPads and stops there. Understudy fills that gap with private system API, which carries real costs. See [Caveats](#caveats).

Protected video will not show up. Netflix, Apple TV+ and anything else using DRM will render as a black rectangle. macOS blocks screen capture of protected content at a level no application can reach around.

It will also never appear on the Mac App Store. Private API disqualifies it.

## Requirements

- Two Macs running macOS 14 (Sonoma) or newer
- A USB-C or Thunderbolt cable between them
- Screen Recording permission on the host Mac

Wireless is on the roadmap. A cable comes first because latency decides whether this feels like a monitor or like a laggy screen share, and a direct connection removes most of the problem before it starts.

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
              └──────── Thunderbolt / USB-C ───────────┘
                         low-latency transport
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

### Trying it

This part works today. The probe creates a Retina display, checks that macOS registered it at the right geometry, captures frames from it, then removes it.

```bash
swift run understudy-probe 20
```

```
Verifying macOS sees it
────────────────────────────────────────────
  ✓ Appears in the active display list
    #23    1512×982 pts  3024×1964 px  @2.0x  @(-1512, 0)  [HiDPI]
  ✓ Logical resolution matches: 1512×982 pts
  ✓ Backing resolution matches: 3024×1964 px
  ✓ Retina/HiDPI confirmed (2.0x scale)
  ✓ Reported as a secondary external display

Capturing frames
────────────────────────────────────────────
  ✓ Screen Recording permission granted
  ✓ Capture started
  ✓ Frames are arriving
  ✓ Frame size matches the display: 3024×1964 px
  ✓ Frames contain real pixels (peak 153, mean 0.0013)
    45 frames with new content, 124 unchanged
```

The first captured frame is saved as a PNG and the probe prints its path, so you can open it and see exactly what came back.

Two things surprise people here. A freshly created display has no wallpaper on it, so that PNG is mostly black with only a menu bar across the top, and that is correct rather than broken. An idle screen also produces very few frames with new content, because ScreenCaptureKit sends one only when something actually changes.

Open System Settings > Displays while it runs and you will find a second monitor listed. Windows dragged onto it vanish from view, since nothing is being sent to another Mac yet.

## Caveats

Understudy depends on private Apple API. No public alternative exists, and every application in this category makes the same compromise. What that means in practice:

A macOS update can break it. Understudy checks that the classes and methods it needs are still present and reports a clear error if they are not, so you get an explanation rather than a crash. It still stops working until somebody updates it.

Builds you hand to other people need a paid Apple Developer certificate and notarization. Without those, Gatekeeper refuses to open the app.

One more limitation, this one unexplained so far: a process can create a single virtual display. Releasing it and creating another in the same process fails, and the second display never registers. That needs solving before Understudy can drive more than one spare MacBook.

## Roadmap

- [x] Create a Retina virtual display and confirm macOS accepts it
- [x] Capture the virtual display with ScreenCaptureKit
- [x] Hardware HEVC encode and decode, tuned for latency ahead of quality
- [ ] Wired transport over Thunderbolt Bridge
- [ ] Client app rendering fullscreen through Metal
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
