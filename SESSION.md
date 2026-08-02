# Understudy — session log

Working notes from the session that built this, kept so context survives a
compaction. Written for whoever picks it up next, including future me.

**Repo:** https://github.com/chachasmooth/Understudy (public, GPL-3.0)
**Local:** `/Users/charlesm/Desktop/My Projects/Project 1`
**Owner:** chachasmooth. Non-technical; wants explanations in plain language and
the implementation done for him, not handed to him as instructions.

---

## What it is

Turn a spare MacBook into a second display for another Mac, over Wi-Fi.
macOS sees a genuine second monitor, not a screen-sharing window.

Verified working across two machines: an **M5 MacBook Air** (host) streaming to
an **M1 MacBook Air 13.3-inch** (client), 47 to 49 fps, zero dropped frames,
peaking at 51 Mb/s while a window was dragged around.

---

## Decisions taken, and why

| Decision | Reason |
|---|---|
| Wi-Fi, not Thunderbolt | Originally cable-first. Reversed once measured: the stream is ~40 Mb/s peak, so Wi-Fi has ample headroom, and a cable-only product is one nobody can try. Cable still works, it is just ordinary TCP over whatever interface exists. |
| GPL-3.0, not MIT | Owner's call. MIT let anyone ship a closed commercial fork. GPL-3.0 also carries its own patent grant, so Apache was unnecessary. |
| No Developer ID ($99/yr) | Owner declined. Consequences are real: see Known problems. |
| Display only, no input forwarding | Owner's call at the outset. Universal Control already does cursor and keyboard. |
| M-series MacBooks only | All have hardware HEVC encode and decode. Intel untested. |
| One app, role chosen at launch | Replaced two CLI tools, which were deleted. |

---

## Architecture

```
Sources/
  CVirtualDisplay/     ObjC. The ONLY private-API code. USVirtualDisplay.
  UnderstudyKit/       VirtualDisplay, DisplayCapture, FrameEncoder/Decoder,
                       StreamProtocol, StreamTransport, HostSession, ClientSession
  Understudy/          The SwiftUI app. Both roles.
  understudy-probe/    Diagnostic CLI. Exercises every stage on one machine.
Tools/
  build-app.sh         Builds and ad-hoc signs Understudy.app + release zip
  dump-private-api.m   Prints live signatures of Apple's private classes
install.sh             curl | bash installer for end users
```

Pipeline: **virtual display → ScreenCaptureKit → VideoToolbox HEVC → TCP+TLS →
VideoToolbox decode → AVSampleBufferDisplayLayer.**

---

## Hard-won technical findings

Everything here cost real debugging time. `docs/ARCHITECTURE.md` has the full
version; this is the short list.

1. **Private CoreGraphics classes are not linkable.** `CGVirtualDisplay` and
   friends exist in CoreGraphics but are absent from the SDK stub. Resolved at
   runtime with `objc_getClass`; interfaces re-declared locally for the compiler.

2. **HiDPI:** `maxPixelsWide/High` = pixel size, `settings.modes` = a single mode
   at *point* size, `hiDPI = 1`. Expressing the mode in pixels does not work.

3. **Reading display geometry needs two APIs.** `CGGetActiveDisplayList` for the
   list, `NSScreen.backingScaleFactor` for scale. `CGDisplayCopyDisplayMode`
   returns nil for fresh virtual displays and was removed after proving useless
   in the exact case it was added for. Do not re-add it.

4. **`NSScreen.screens` is cached** until an AppKit run loop turns. First read
   wins for the process lifetime. Anything touching `NSApplication.shared`
   counts as a read. The probe avoids AppKit before creating its display.

5. **Do NOT set `EnableLowLatencyRateControl`.** Despite the name it forces HEVC
   onto the *software* encoder: 12.4 ms/frame vs 6.3 ms with hardware.
   `FrameEncoder.isHardwareAccelerated` reports what was actually chosen and the
   probe fails if it is software.

6. **BGRA vs YUV input costs ~0.2 ms.** Irrelevant. Capture stays BGRA.

7. **HEVC parameter sets (VPS/SPS/PPS) must be sent explicitly.** In-process the
   decoder gets them free from the encoder's format description. Over a socket
   the client has nothing until they arrive as their own message.

8. **ScreenCaptureKit only delivers a frame when something changes.** A still
   screen produces none. This is why `HostSession` keeps the last frame and has
   a 1 Hz heartbeat.

9. **Only ONE virtual display can exist at a time, machine-wide.** Not per
   process, as originally documented. A leaked display blocks every other
   process from creating one.

10. **`dispatch_sync` on your own queue traps.** Both `StreamServer` and
    `StreamClient` mark their queue with a specific key and run synchronous
    accessors inline when already on it.

11. **Ad-hoc signing means the app's identity is a hash of the binary.** Every
    rebuild is a "different app" to macOS, so Screen Recording permission must
    be re-granted every single time. This bit ~8 times in one session.

12. **`.windowResizability(.contentSize)` blocks fullscreen.** It drops
    `.resizable` from the style mask, and `toggleFullScreen` silently no-ops on
    a non-resizable window.

---

## Bugs found and fixed

In order, with cause:

- **Probe reported non-Retina** — was reading via `CGDisplayCopyDisplayMode`,
  which returns nil for new virtual displays; the fallback silently reported the
  point size as the pixel size.
- **Encode at 70 ms/frame** — `EnableLowLatencyRateControl` forcing software.
- **Two tests that could not fail** — encoder had no hardware check; the socket
  test asserted `arrived + dropped >= sent`, true no matter how much was
  discarded. It passed while dropping 38 of 39 frames.
- **Client showed nothing** — host had no frame to send on a still screen. Fixed
  with a retained last frame plus a 1 Hz heartbeat.
- **Picture froze permanently** — client flushed its display layer then fed it a
  delta frame, which a flushed decoder cannot use, so it flushed again forever.
  Every frame already carried an `isKeyframe` flag that was being discarded.
- **Host crashed on connect** — `onClientConnected` fires on the server queue and
  `isConnected` did `queue.sync` on that same queue.
- **Leaked virtual display** — a partially-failed host left its display behind,
  holding the machine's only slot.
- **Fullscreen never engaged** — two causes: `WindowAccessor` was never actually
  in `ClientView` (a scripted edit silently did not match and reported success),
  and `.contentSize` made the window non-resizable.
- **Client stranded after fullscreen** — window kept its fullscreen frame, so the
  code panel sat in the corner of a black screen with clipped digits.
- **13-inch Air preset was wrong** — held 2560×1664 (the 13.6-inch M2) while
  named for the 13-inch. The M1's panel is 2560×1600. All five presets now
  checked against Apple's published specs.
- **The second screen was black, and that was the whole mystery.** macOS paints
  a wallpaper on a physical monitor but leaves a virtual display bare, so the
  second screen was pure black apart from the menu bar. That looks identical to
  a broken stream. Hours went into the pipeline, which was working perfectly the
  entire time. `NSWorkspace.setDesktopImageURL(_:for:)` fixes it per screen.
- **Host could report started while not listening** — the listener's state
  handler covered `.ready` and `.failed` only, so one stuck in `.waiting`
  reported neither. Display already created, sitting there as a phantom screen.
- **Client waited forever on "Pairing..."** — Bonjour keeps advertising a host
  after it stops, so `NWConnection` chased a dead address indefinitely. Now a
  ten-second deadline.
- **`install.sh` could silently do nothing** — it cannot replace a running app
  and reported success anyway. This is how the spare stayed on 0.1.0 for hours
  while both of us assumed it was current. It now prints the installed version,
  and the app shows its version on the first screen.
- **Fullscreen never engaged** — `WindowAccessor` was never actually in
  `ClientView` because a scripted edit silently did not match, *and*
  `.windowResizability(.contentSize)` made the window non-resizable, which makes
  `toggleFullScreen` a silent no-op.
- **`Sources/Understudy/UnderstudyApp.swift` was deleted from the working tree**
  by something unidentified mid-session. Recovered from HEAD. Cause unknown.
- **CLI tools silently rotted** — `understudy-host`/`understudy-client`
  duplicated `HostSession`/`ClientSession` and received none of the above fixes.
  Deleted.

---

## Known problems, unsolved

### THE BLACK SCREEN — solved in v0.1.17

**The video layer was zero by zero pixels.** The stream had been working the
whole time.

`VideoLayerView` did two things the working command-line client never did. It
replaced the view's backing layer after the view was already layer-backed
(`view.wantsLayer = true` then `view.layer = CALayer()`, which Apple documents
as the wrong order), and it set the video layer's frame only from
`updateNSView`. Neither ever gave the layer a size.

Measured, not assumed. A standalone harness built both patterns side by side in
the same SwiftUI window and printed their geometry:

    before fullscreen
        A attached yes  frame (0.0, 0.0, 0.0, 0.0)      <- the app's pattern
        B attached yes  frame (0.0, 0.0, 900.0, 418.0)  <- the script's pattern

A stayed at 0x0 through six body re-renders and through the fullscreen
transition. The per-second diagnostics timer re-renders the body every second
and still never fixed it, because SwiftUI does not re-run `updateNSView` for an
AppKit-driven resize.

**Why this looked like a network bug.** A zero-sized `AVSampleBufferDisplayLayer`
accepts every frame, decodes it, and reports `.rendering`. So the client honestly
said `frames 936  last 0.4s ago  rendering` while painting nothing. Every visible
number was healthy because every number was true.

**Why the scripts worked and the app did not.** `understudy-client/main.swift`
set `videoLayer.frame = content.bounds` and
`autoresizingMask = [.layerWidthSizable, .layerHeightSizable]`, and added the
sublayer to AppKit's own layer instead of replacing it. The app now does the
same, verified to track resizes from 900x418 to 1440x868 to 700x368.

**Things that were suspected and cleared, in order:**

1. Dropped keyframes breaking the HEVC reference chain. Plausible, and wrong.
2. `private let layer = AVSampleBufferDisplayLayer()` on a SwiftUI View struct
   being re-created per render, so frames went to an orphaned layer. Tested with
   a harness: SwiftUI creates it once. Wrong.
3. 3 fps and 0.3 Mb/s reading as a stalled send path. They are consistent with an
   idle desktop plus the 1 Hz heartbeat. ScreenCaptureKit only delivers on change.

**The lesson, again.** Two days of theories about the network, and the answer was
a rectangle with no width. Three harnesses, ten minutes, done. Build the thing
that prints the number.

**Windows dragged to the second screen: WORKING.** Verified once the layer fix
landed. Windows pushed off the chosen edge land on the second screen and stay
there. This was the original point of the project and it had never once been
confirmed before v0.1.17, because the black screen hid it.

**Permissions reset on every rebuild.** Ad-hoc signing. A self-signed
certificate from Keychain Access would give a stable identity and fix it
permanently; offered several times, declined so far. This also affects end users:
every update revokes their Screen Recording grant.

**Universal Control competes for the screen edge.** Genuinely unfixable in code:
CoreGraphics does not report the link as a display, so Understudy cannot detect
it. README now says to turn it off, with "use an unused edge" as the alternative.

**No glass-to-glass latency number.** Frame arrival gaps measure smoothness, not
delay. A real figure needs clock sync between the machines.

**47 fps, not 60.** Small, cause unknown, never investigated.

**Gatekeeper.** Unsigned, so `install.sh` clears the quarantine flag. Homebrew
stops accepting unsigned casks on 1 September 2026, so direct download plus the
installer is the only route without paying.

---

## Working practices that mattered

- **Verify, do not assume.** Two shipped bugs were tests that could not fail.
  Every check should be asked: what would make this fail?
- **Scripted edits must fail loudly.** A python `str.replace` that does not match
  and still prints success cost two rounds of "fixed" that was not.
- **A blank output is not evidence of a broken pipeline.** The single most
  expensive mistake of the session. Instrument the endpoint before theorising
  about the path; `frames 936, last 0.4s ago, rendering` on the client settled in
  one screenshot what four hypotheses had not.
- **Capture the pixels and look at them.** Twice this ended a long argument: the
  black-frames question early on, and the wallpaper discovery at the end.
- **The probe cannot see everything.** Crash reports, screenshots and version
  mismatches between the two machines were all caught by the owner, not the
  probe.
- **Update BOTH machines.** Client-side fixes are invisible if only the host is
  rebuilt. This wasted a long stretch of testing.
- Every macOS release: re-run `Tools/dump-private-api.m` and compare against
  `USVirtualDisplay.m`.

---

## Commands

```bash
# Build and install locally
./Tools/build-app.sh 0.1.x && cp -R build/Understudy.app /Applications/

# Full diagnostic on one machine
swift run understudy-probe 10

# Cut a release
gh release create v0.1.x build/Understudy.zip --title "..." --notes "..."

# What users run
curl -fsSL https://raw.githubusercontent.com/chachasmooth/Understudy/main/install.sh | bash
```

CI runs on `macos-15`: builds, runs pure-logic tests, and fails if Apple's
private classes have disappeared. Runners are headless, so nothing that creates
a display can be tested there.
