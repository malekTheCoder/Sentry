# Sentry

**A macOS menu bar system monitor with iPhone and Apple Watch companions —
and a built-in manager for the AI agents running on your Mac.**

Live charts over a local history store, battery health trends, alert rules,
keep-awake, fan and thermal monitoring, and an MCP integration layer that
lets coding agents check your Mac's capacity before they start heavy work.
No cloud, no accounts, no telemetry: your Mac's data goes to your phone and
your watch, never to a server.

[![Download](https://img.shields.io/github/v/release/malekTheCoder/Sentry?label=download&color=blue)](https://github.com/malekTheCoder/Sentry/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20%7C%20iOS%2017%2B%20%7C%20watchOS%2010%2B-lightgrey)

<p align="center">
  <img src="docs/screenshots/macos-dashboard.png" alt="The macOS dashboard: live CPU, memory, and GPU charts over a 24-hour history, battery health, and keep-awake controls" width="840">
</p>

<p align="center">
  <img src="docs/screenshots/ios-dashboard.png" alt="iPhone dashboard, live from the Mac" width="215">&nbsp;
  <img src="docs/screenshots/ios-history.png" alt="iPhone History tab: battery health trend and every metric's latest reading" width="215">&nbsp;
  <img src="docs/screenshots/ios-alerts.png" alt="iPhone alert rules" width="215">
</p>

<p align="center">
  <img src="docs/screenshots/watch-overview.png" alt="Apple Watch overview: battery, CPU, memory, and disk dials" width="200">&nbsp;&nbsp;&nbsp;
  <img src="docs/screenshots/macos-menubar.png" alt="The menu bar dropdown: system verdict and vitals at a glance" width="300">
</p>

## Install

**[⬇ Download Sentry.dmg](https://github.com/malekTheCoder/Sentry/releases/latest/download/Sentry.dmg)** — then open it and drag **Sentry** into **Applications**.

Requires macOS 14 (Sonoma) or later, Apple Silicon or Intel.

Releases are signed with a Developer ID certificate and notarized by
Apple, so the app opens with no security warnings. Each release's notes
include a SHA-256 checksum for the DMG. Starting with v1.0.1, installed
copies update themselves through Sparkle from a signed appcast.

> Sentry ships outside the Mac App Store by necessity, not choice — it
> reads low-level power and thermal interfaces (`libIOReport`,
> `IOHIDEventSystemClient`) that do not exist inside the App Sandbox the
> App Store requires.

**iPhone & Apple Watch:** the companion app is coming to the App Store
(link will land here when it's live) — the watch app installs automatically
with the iPhone app. Both are built from this same repo (`SentryMobile`,
`SentryWatch`). Open the app on the iPhone while the Mac app is running on
the same Wi-Fi and they find each other over Bonjour; away-from-home
access works too, over a TLS listener the phone pairs with by QR code.

## Features

Everything is free. There is no paid tier, no license key, and nothing to
buy — see [License](#license).

**On the Mac** — a menu bar readout (monochrome, layout-configurable) with
a themed dropdown; a Dashboard of live charts backed by a local GRDB
history store with tiered rollups; alert rules with history; keep-awake
timers; fan RPM readout everywhere; built-in themes, each with light,
dark, and follow-the-system variants; a security-posture check of your
Mac's protections, read-only and local; conditional keep-awake release
rules (battery level, sustained CPU, a named app or process, an active
download, or a schedule); process-match alert rules; a custom theme editor
with WCAG contrast checking; history export and whatever retention you set;
and Protection Insights — every finding in full, with a battery-health
degradation ETA, thermal cool-down estimates, and energy use in kWh by
day, week or month.

**On iPhone and Apple Watch** — a companion iPhone app and a three-page
Watch app (overview, keep-awake, agent activity — with a kill-switch
resume path and its own Siri intents), fed over local-network sync
(Bonjour). Reconnection is keepalive-backed and sleep/wake-aware, and
reconnects prefer the last-connected Mac rather than whichever one answers
first. Shortcuts/Siri work locally, in-process, with no network hop.

**For agents and scripts** — an MCP server in two transports (stdio via
`SentryMCP` for Claude Desktop/Code/Cursor; optional LAN HTTP gated by an
API key), with per-tool toggles, per-client rate limiting, and
confirmation gates on write tools, all in Settings ▸ AI Access. Past
permissions, this is a real agent *manager*: `preflight_check` returns a
structured proceed/caution/wait/do-not-start verdict with reasons and a
wait estimate before an agent starts heavy work; `get_agent_capacity`
shows what other sessions are active so two agents don't contend;
per-session resource attribution reports what a session actually cost in
battery, thermals, and awake time; guardrails (battery floor, quiet hours,
thermal auto-revoke) and a kill switch — global or per-client — keep an
agent from running the Mac hot while nobody's watching. The `sentryctl`
CLI mirrors the same controls from the shell, including a packaged Claude
Code plugin bundle under
[`integrations/claude-code/plugin/`](integrations/claude-code/plugin/README.md).
Copy-pasteable configs live in
[`docs/integrations/`](docs/integrations/README.md).

Issues and pull requests are welcome — see
[`CONTRIBUTING.md`](CONTRIBUTING.md) for how the project is laid out, how
to run the test suite, and what a good PR looks like. Maintainers cutting a
release should follow [`docs/release-checklist.md`](docs/release-checklist.md)
and run `scripts/release.sh`.

## License

Sentry is free and open source under the [MIT License](LICENSE), © Malek
Swilam & Aniketh Bandlamudi. Every feature is available to everyone, in
the official builds and in any build you make yourself — there is no paid
tier, no license key, and no telemetry funding one. A "Sentry Pro" tier
was planned and partly built (a one-time purchase, an Ed25519 license
format, six gated features); it was cancelled before any checkout existed,
and the whole apparatus has been removed rather than disabled. Bundled
open-source dependencies are acknowledged in
[`docs/third-party-licenses.md`](docs/third-party-licenses.md).
