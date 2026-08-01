# Contributing to Understudy

Thanks for taking an interest. This is a hobby project built in the open, and
help is genuinely welcome.

## Getting set up

```bash
git clone https://github.com/chachasmooth/Understudy.git
```

```bash
cd Understudy && swift build && swift test
```

You need macOS 14 or later. Xcode Command Line Tools are enough to build the
library and run the probe. **`swift test` additionally requires full Xcode**,
because XCTest is not part of Command Line Tools. If you only have the
latter, CI will run the tests for you on your pull request. Full Xcode will also be
needed once app bundles arrive in milestone 5.

To check the virtual display works on your machine:

```bash
swift run understudy-probe 20
```

## Where to start

Open issues labelled `good first issue` are the easiest entry point. Beyond
that, the [roadmap](README.md#roadmap) lists what is unbuilt, and these are
genuinely open questions worth investigating:

- **Multiple displays per process.** Creating a second virtual display after
  releasing the first fails. Working out why would unblock support for several
  spare MacBooks.
- **Testing on other macOS versions.** Understudy is verified on macOS 26.5.
  Reports from 14.x and 15.x are valuable. Run the probe and open an issue with
  the output either way.

## Working with the private API

Understudy depends on undocumented Apple API. Two rules keep that manageable:

1. **Keep it contained.** All private-API use lives in
   `Sources/CVirtualDisplay/USVirtualDisplay.m`. Nothing else should reference
   `CGVirtualDisplay*` types. If a change seems to need it elsewhere, that is
   worth discussing in an issue first.
2. **Fail loudly and clearly.** Check that classes exist and that objects
   respond to selectors before calling them, and return a descriptive
   `USVirtualDisplayError`. A user on an unsupported macOS should get a sentence
   explaining the problem, never a crash.

Signatures come from the runtime, not from guesswork. Before changing a private
call, run:

```bash
clang -fobjc-arc -framework Foundation Tools/dump-private-api.m -o /tmp/dump && /tmp/dump
```

## Style

- Swift and Objective-C, 4-space indent, no tabs. `.editorconfig` covers the rest.
- Comments explain **why**, not what. The code already says what it does.
- Document surprising behaviour where it lives. Several APIs here fail in
  non-obvious ways, and a comment recording that saves the next person an hour.
- Public API gets doc comments.

## Tests

`swift test` runs in CI on headless GitHub runners, which have **no display
server**. Tests must therefore be pure logic. Anything that creates a real
display will fail there. Hardware-dependent verification belongs in
`understudy-probe`, run manually.

## Pull requests

- One concern per PR.
- Say what you tested and on which macOS version. "Ran the probe on 15.2, all
  checks passed" is exactly the right level of detail.
- Update `CHANGELOG.md` under `Unreleased` for user-visible changes.
- CI must pass.

## Reporting bugs

Use the issue templates. For anything display-related, include the full output
of `swift run understudy-probe` and your macOS version. That output is designed
to answer most of the questions a maintainer would otherwise have to ask.

## Security

Please don't open public issues for security problems. See [SECURITY.md](SECURITY.md).
