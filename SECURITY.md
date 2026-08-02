# Security Policy

## Supported versions

Only the latest release and the latest commit on `main` are supported. This is
a hobby project with one maintainer, so older versions get no backported fixes.
Update before reporting anything.

## Reporting a vulnerability

Please report security issues privately rather than in a public issue.

Use [GitHub's private vulnerability reporting](https://github.com/chachasmooth/Understudy/security/advisories/new),
which is the preferred route.

Please include what the issue is, how to reproduce it, and what an attacker
could achieve. You'll get an acknowledgement within a few days. This is a hobby
project maintained in spare time, so please be patient with fix timelines. I
take credible reports seriously, and you'll be credited in the advisory
unless you'd rather not be.

## Threat model

Understudy is worth thinking about carefully, because of what it handles:

- **It captures your screen.** The host app requires Screen Recording
  permission and reads the contents of a display. Anything that could cause
  those frames to reach an unintended destination is a serious bug.
- **It opens a network listener.** The host advertises itself over Bonjour and
  accepts connections. Anything that can connect can see the extended desktop.
  Access is gated by a six digit code shown on the host, which becomes the TLS
  pre-shared key for the connection, so a peer without it cannot complete the
  handshake and never receives a frame. Weaknesses in that pairing are the most
  security-relevant part of the project.
- **The code is six digits and generated per session.** That is short. It is
  chosen to be typed by a person looking at another screen in the same room,
  which is the intended threat model. If you can reach the listener and are
  willing to grind the handshake, say so in a report rather than assuming it is
  a known trade-off.
- **It uses private system API.** This is a stability and compatibility risk
  rather than a security one. The calls create a display and do not elevate
  privileges, though it is still worth knowing about.

Understudy does not phone home, collect analytics, or make outbound network
connections other than to a client Mac you have paired with.

## Out of scope

- The fact that Understudy relies on undocumented Apple API. This is a known,
  documented design constraint. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- Anything requiring an attacker to already have admin access to your Mac.
- Ad-hoc signing. Releases are not notarized and Gatekeeper says so. That is a
  documented trade-off rather than a defect, and the installer is short enough
  to read before running.
