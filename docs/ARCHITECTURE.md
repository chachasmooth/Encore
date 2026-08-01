# Architecture

How Understudy is put together, and why. This document records findings that
cost real debugging time, so nobody has to rediscover them.

## Layout

```
Sources/
  CVirtualDisplay/     Objective-C. The only code that touches private Apple API.
  UnderstudyKit/       Swift. Display management and shared types.
  understudy-probe/    Diagnostic CLI that proves the virtual display works.
Tools/
  dump-private-api.m   Prints the live signatures of Apple's private classes.
Tests/
  UnderstudyKitTests/  Pure-logic tests. No display creation — CI is headless.
```

The private-API surface is deliberately tiny and sits behind
`USVirtualDisplay`, which exposes a normal Objective-C class with normal errors.
Swift never sees a private type. When a future macOS release changes something,
exactly one file needs attention.

## Creating a display macOS believes in

macOS has no public API for registering a virtual monitor. DriverKit exposes no
graphics driver class, and `CoreMediaIO` plugins are cameras, not displays. The
only route is four private CoreGraphics classes:

| Class | Role |
|---|---|
| `CGVirtualDisplayDescriptor` | Identity and physical characteristics |
| `CGVirtualDisplayMode` | One resolution + refresh rate |
| `CGVirtualDisplaySettings` | Mode list, HiDPI flag, rotation |
| `CGVirtualDisplay` | The display itself |

The display exists for exactly as long as the `CGVirtualDisplay` object is
retained. Releasing it unregisters the monitor, which is why `VirtualDisplay`
must be held by the host app for the session's lifetime.

### The symbols are not linkable

The classes live in CoreGraphics, but `_OBJC_CLASS_$_CGVirtualDisplay` and
friends are **absent from the SDK stub** (`CoreGraphics.tbd`). Referencing them
directly fails at link time.

They are therefore resolved at runtime with `objc_getClass`, and the interfaces
are re-declared locally purely to give the compiler type information. Declaring
an `@interface` emits no symbol; only messaging a class by name would.

`+[USVirtualDisplay isSupported]` checks all four classes exist, and each
required selector is checked with `respondsToSelector:` before use, so an API
change surfaces as `USVirtualDisplayErrorIncompatibleAPI` rather than a crash.

Signatures were read off the live runtime rather than copied from a header.
Re-run `Tools/dump-private-api.m` after each major macOS release to check:

```bash
clang -fobjc-arc -framework Foundation Tools/dump-private-api.m -o /tmp/dump && /tmp/dump
```

### Getting a Retina display

Verified on macOS 26.5. To produce a HiDPI display of *W*×*H* points:

- `descriptor.maxPixelsWide/High` = the **pixel** size (2W × 2H)
- `settings.modes` = a single mode at the **point** size (W × H)
- `settings.hiDPI` = 1

macOS then reports a display of W×H points backed by 2W×2H pixels. Expressing
the mode in pixels instead does not produce a HiDPI display.

## Reading display geometry is genuinely hard

Three APIs report screen geometry, and each is unreliable in a different way.
Understudy uses all three because no single one is trustworthy.

| API | Gives | Fails when |
|---|---|---|
| `CGGetActiveDisplayList`, `CGDisplayPixelsWide` | Point size, always current | Never — but only reports points |
| `CGDisplayCopyDisplayMode` | True pixel size | Returns **nil** for freshly created virtual displays in some processes, from Objective-C as well as Swift |
| `NSScreen.backingScaleFactor` | Scale factor, public and documented | `NSScreen.screens` is **cached** until an AppKit run loop processes a screen-change notification |

`DisplayInfoReader` enumerates with CoreGraphics and resolves scale from
NSScreen. `CGDisplayCopyDisplayMode` was tried as a fallback for when NSScreen
is stale and has since been removed: in that exact situation it returns nil too,
so it never rescued a single case. Don't re-add it without new evidence.

`DisplayInfo.scaleFactor` is optional because there are moments when neither
remaining source can answer honestly. Reporting a guess would silently look like
a non-Retina display, which is the bug that cost the most time to find.

### The NSScreen cache trap

`NSScreen.screens` is populated on first access and only refreshed when an
AppKit run loop processes `NSApplicationDidChangeScreenParametersNotification`.
In a command-line process there is no such loop, so **the first read wins for
the lifetime of the process**.

Anything that initialises AppKit counts as a read — including
`NSApplication.shared` and `finishLaunching()`. `understudy-probe` therefore
deliberately avoids both, and lists pre-existing displays using CoreGraphics
only. Reading `NSScreen` before creating the virtual display makes the display
appear non-Retina forever afterwards.

A real GUI app is unaffected, because it creates displays after `NSApp` is
already running and processing notifications.

## Known limitations

**One virtual display per process.** Creating a second display after releasing
the first fails in the same process: `applySettings:` succeeds, a display ID is
assigned, but the display never registers and reports 0×0. Whether two
*simultaneous* displays work is untested. This needs resolving before Understudy
can drive several spare MacBooks at once.

**DRM content captures as black.** ScreenCaptureKit refuses protected content.
Unfixable.

## Capture

`DisplayCapture` runs an `SCStream` filtered to the virtual display's ID,
delivering `CVPixelBuffer`s on a dedicated queue rather than the main one, so a
slow consumer stalls capture instead of the interface.

Two behaviours are worth knowing before debugging anything here.

**Most frames carry nothing new.** ScreenCaptureKit attaches a status to every
frame and only `.complete` means fresh content. An idle desktop produces mostly
non-complete frames, so a low delivered-frame count on a static screen is
correct rather than a fault. `DisplayCapture` counts those separately in
`idleFrameCount` and does not pass them on, because re-encoding an unchanged
screen spends bandwidth for no visible gain.

**A missing permission looks like success.** Without Screen Recording access
macOS still starts the stream and still delivers frames at exactly the right
size. Every pixel is simply zero. Average brightness cannot detect this, because
a newly created virtual display has no wallpaper and no windows on it, so a
perfectly good capture of one also averages near zero. The probe therefore tests
the *peak* pixel value, which only real content can raise, and writes the first
frame to a PNG so the question can be settled by looking.

## Encoding

`FrameEncoder` and `FrameDecoder` wrap VideoToolbox HEVC. B-frames are disabled,
because a B-frame references a future frame and the encoder cannot emit anything
until that frame arrives, which is unusable for live output.

**Do not set `EnableLowLatencyRateControl`.** The name suggests exactly what this
project wants, and it does the opposite: on macOS 26 it forces HEVC onto the
software encoder. Measured at 3024×1964:

| Configuration | Hardware | ms/frame |
|---|---|---|
| Low-latency rate control | no | 12.4 |
| Default rate control | yes | 6.3 |

It does produce smaller frames, but bitrate is not the constraint over a cable
and latency is the whole product. `FrameEncoder.isHardwareAccelerated` reports
what VideoToolbox actually picked, and the probe fails if it is software, so a
future regression here surfaces immediately instead of as vague sluggishness.

Pixel format barely matters, incidentally. Feeding the encoder BGRA rather than
4:2:0 YUV costs about 0.2 ms per frame at this size, so capture stays BGRA and
frames can be inspected without a conversion step.

Round-trip measurements on an idle desktop: encode 10 to 13 ms per frame, decode
about 5 ms, output identical in size to the input and visually intact. Compression
lands between 6000:1 and 9000:1, though that number flatters itself on a mostly
static screen and will fall sharply with real content in motion.

## Planned pipeline

Milestones 4 and 5, not yet built:

1. **Transport** — length-prefixed frames over TCP on the Thunderbolt Bridge
   interface. A direct cable gives 10 Gbps and near-zero loss, so the first
   implementation needs no congestion control or retransmission — complexity
   that only wireless will require.
2. **Render** — decoded frames into a `CAMetalLayer`, presented fullscreen.

The latency target is **under 30 ms glass-to-glass**. Past roughly 60 ms it
stops feeling like a monitor and starts feeling like screen sharing, which is
the difference between a tool people use daily and one they try once.
