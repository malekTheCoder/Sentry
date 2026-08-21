# Security policy

Sentry is a system monitor that, with the user's explicit opt-in, installs
a background helper and opens network listeners. That makes security reports
about it worth taking seriously, and worth reporting privately.

Sentry does **not** run any code as root. It used to be able to: a root
LaunchDaemon (`SentryFanDaemon`) could write SMC fan keys on behalf of a
fan-control feature that has since been removed. Fan speeds are now read
and displayed, never set. The app carries a one-time uninstaller
(`Sentry/App/FanDaemonUninstaller.swift`) that unregisters that daemon on
launch for anyone who installed it, and reports of it failing to do so —
leaving an orphaned root job behind — are in scope for this policy.

## Supported versions

| Version | Supported |
| --- | --- |
| The latest release | Yes |
| Anything older | No — update via the in-app updater, or download the [latest DMG](https://github.com/malekTheCoder/Sentry/releases/latest/download/Sentry.dmg) |

Only the latest release receives fixes. The Mac app ships outside the Mac
App Store and updates through a single Sparkle feed; security fixes ship
as a new release on that feed, never as patches to old versions. The app
requires macOS 14 or later.

## Reporting a vulnerability

Please do **not** open a public issue for a security problem.

- **Preferred:** GitHub's private vulnerability reporting on this
  repository — [Security ▸ Report a vulnerability](https://github.com/malekTheCoder/Sentry/security/advisories/new).
  The report stays private between you and the maintainers until a fix is
  out.
- **Email:** TO-FILL(support-email)

Include what you would for any bug — macOS version, hardware, app version —
plus reproduction steps and your assessment of impact. A proof of concept
helps; a patch is welcome but not expected.

**What to expect.** This is a two-person project with no security team.
You will get an acknowledgement within 7 days, and updates as the
investigation progresses. Confirmed vulnerabilities are fixed in the next
release, prioritised by severity; for anything serious, that means a
dedicated release rather than waiting for a planned one. Please hold
public disclosure until a fixed release has shipped, or 90 days from your
report, whichever comes first — and note that because the app has zero
telemetry, users learn about the fix only through the update feed, so a
little patch-adoption time after release is appreciated.

## Scope

The app installs one helper process, opt-in, shipped inside the app
bundle and registered via `SMAppService`:

- **`SentryMCPBridge` — a user-level LaunchAgent** (label
  `dev.malekswilam.sentry.xpc`), installed only when the user enables
  command-line / AI access. It brokers Mach-service connections between
  local clients and the app. Impersonation of either end, or reaching
  tools past the app's permission layer, is in scope.

Also in scope:

- The network listeners: the local sync stream, the TLS-PSK remote sync
  listener (port 8643 by default), and the remote MCP listener (port 8642
  by default) — authentication bypass, memory safety, or reading more
  than the documented snapshot.
- The MCP permission layer: executing action tools that are disabled,
  bypassing the confirmation dialogs, rate limit, or kill switch.
- The Sparkle update chain: anything that gets an unsigned or downgraded
  build installed, given the compiled-in feed URL and public key.

Known, documented limitations — see
[`docs/privacy-policy.md`](docs/privacy-policy.md) — are design tradeoffs
rather than vulnerabilities, though reports that make them cheaper to fix
are welcome: the local read-only stats stream is unauthenticated and
unencrypted on the local network, and the optional remote AI access
listener is plain HTTP with a bearer token.

Out of scope: anything requiring existing root or physical access,
denial of service against the local listeners from the same LAN, and
reports about the Sentry.io service, which is an unrelated product that
happens to share the name.

One consequence of the zero-telemetry design worth knowing as a reporter:
there is no crash reporting or analytics, so the maintainers cannot see
exploitation in the field. Your report may be the only signal that a
problem exists — detailed reproduction steps matter more here than in
most projects.
