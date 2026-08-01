# Security Policy

## Supported versions

Understudy is in early development. Only the latest commit on `main` is
supported. There are no released versions yet.

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
- **It opens a network listener.** Once transport lands, the host will accept
  connections. A client that can connect can see the extended desktop. Pairing
  and authentication are on the roadmap and are treated as security-relevant,
  not as polish.
- **It uses private system API.** This is a stability and compatibility risk
  rather than a security one. The calls create a display and do not elevate
  privileges, though it is still worth knowing about.

Understudy does not phone home, collect analytics, or make outbound network
connections other than to a client Mac you have paired with.

## Out of scope

- The fact that Understudy relies on undocumented Apple API. This is a known,
  documented design constraint. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- Anything requiring an attacker to already have admin access to your Mac.
