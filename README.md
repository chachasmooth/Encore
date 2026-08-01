<div align="center">

# Understudy

**Turn a spare MacBook into a second display for your Mac.**

[![CI](https://github.com/chachasmooth/Understudy/actions/workflows/ci.yml/badge.svg)](https://github.com/chachasmooth/Understudy/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](#requirements)
[![Status](https://img.shields.io/badge/status-early%20development-orange.svg)](#project-status)

*An understudy is the performer who steps in when the lead can't go on.
Your old MacBook has one more role in it.*

</div>

---

## Project status

**Early development. Not yet usable as a monitor.**

The hardest technical question — *can we make macOS believe in a display that
isn't there?* — is answered and working. Video streaming is not built yet.

| Milestone | State |
|---|---|
| **1. Virtual display** — make macOS report an extra Retina monitor | ✅ Working, verified on macOS 26.5 |
| 2. Capture — pull frames off that display efficiently | ⬜ Not started |
| 3. Encode & transport — get frames to the other Mac over a cable | ⬜ Not started |
| 4. Client — decode and render fullscreen | ⬜ Not started |
| 5. App — one download, pick a role, done | ⬜ Not started |

Follow along or star the repo if you want to know when it works end to end.

## What it will do

Connect two Macs with a single USB-C cable. The spare one becomes a real
second display for the main one — drag windows onto it, put your reference
docs there, extend your desktop.

macOS treats it as genuine hardware, not a screen-sharing window. The cursor
crosses onto it naturally, windows remember their positions, and it shows up in
System Settings → Displays like any monitor.

## What it won't do

Being straight with you up front:

- **It is not Sidecar.** Apple provides no supported way to make one Mac act as
  a display for another. Understudy works around that, and the workaround has
  real costs — see [Honest caveats](#honest-caveats).
- **It won't show DRM-protected video.** Netflix, Apple TV+ and similar will
  render as a black rectangle. macOS refuses to let any app capture protected
  content, and there is no way around that.
- **It won't be on the Mac App Store.** It can't be. See below.

## Requirements

- Two Macs running **macOS 14 (Sonoma) or later**
- A **USB-C or Thunderbolt cable** between them (wireless is on the roadmap, but
  a cable is what makes this feel like a monitor rather than a screen share)
- Screen Recording permission on the host Mac

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

The trick is step one. macOS has no public API for creating a virtual display,
so Understudy uses a private CoreGraphics interface. Everything that touches it
is confined to [one file](Sources/CVirtualDisplay/USVirtualDisplay.m) so that a
future macOS change breaks one small, well-marked place instead of the whole app.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the details, including the
API quirks that cost real debugging time.

## Building

You need macOS 14+ and Swift 6 (Xcode Command Line Tools are enough for now):

```bash
git clone https://github.com/chachasmooth/Understudy.git
```

```bash
cd Understudy && swift build
```

### Try the virtual display

This is the part that works today. It creates a Retina display, verifies macOS
registered it correctly, holds it open so you can see it in System Settings,
then removes it:

```bash
swift run understudy-probe 20
```

Expected output:

```
Verifying macOS sees it
────────────────────────────────────────────
  ✓ Appears in the active display list
    #23    1512×982 pts  3024×1964 px  @2.0x  @(-1512, 0)  [HiDPI]
  ✓ Logical resolution matches: 1512×982 pts
  ✓ Backing resolution matches: 3024×1964 px
  ✓ Retina/HiDPI confirmed (2.0x scale)
  ✓ Reported as a secondary external display
```

While it runs, open System Settings → Displays. You will see a second monitor
listed, and you can drag windows onto it — they just won't be visible anywhere
yet, because nothing is streaming them.

## Honest caveats

**It relies on private Apple API.** There is no public alternative. Every app in
this category does the same thing. The consequences are real:

- It can break with any macOS update. Understudy detects this and reports a
  clear error rather than crashing, but a break means it stops working until
  someone updates it.
- It can never ship on the Mac App Store.
- Distributed builds need a paid Apple Developer certificate and notarization,
  or macOS Gatekeeper will refuse to open the app.

**Only one virtual display per process has been observed to work.** Creating a
second one after destroying the first fails in the same process. This matters
for supporting several spare MacBooks at once, and needs investigation before
milestone 5.

## Roadmap

- [x] Create a Retina virtual display and verify macOS accepts it
- [ ] Capture the virtual display with ScreenCaptureKit
- [ ] Hardware HEVC encode with VideoToolbox, tuned for latency over quality
- [ ] Wired transport over Thunderbolt Bridge
- [ ] Client app: decode and render fullscreen via Metal
- [ ] Automatic pairing so the two Macs find each other
- [ ] Single app bundle with a host/client role picker
- [ ] Signed and notarized releases
- [ ] Wireless transport
- [ ] Multiple client Macs

Non-goals for now: using the spare Mac's keyboard and trackpad to control the
host, iPad support (Sidecar already does that), and Windows or Linux clients.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). If you're
here because you also thought "surely my old laptop can be a monitor", you're in
the right place.

## License

[MIT](LICENSE)
