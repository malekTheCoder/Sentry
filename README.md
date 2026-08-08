# Sentry

**A macOS menu bar system monitor with iPhone and Apple Watch companions —
and a built-in manager for the AI agents running on your Mac.**

Live charts, battery health trends, thermal insights, alert rules,
conditional keep-awake, real fan control on Apple Silicon, and an MCP
integration layer that lets coding agents check your Mac's capacity before
they start heavy work. No cloud, no accounts, no telemetry: your Mac's data
goes to your phone and your watch, never to a server.

[![Download](https://img.shields.io/github/v/release/malekTheCoder/Sentry?label=download&color=blue)](https://github.com/malekTheCoder/Sentry/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20%7C%20iOS%2017%2B%20%7C%20watchOS%2010%2B-lightgrey)

<p align="center">
  <img src="docs/screenshots/macos-dashboard.png" alt="Sentry's macOS dashboard: live CPU, memory, and GPU charts over a 24-hour history, battery health, and keep-awake controls" width="840">
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

> **First launch:** if macOS reports that it "cannot verify" the app, open
> **System Settings ▸ Privacy & Security**, scroll down, and click
> **Open Anyway** next to Sentry. This happens on builds that have not yet
> been notarized by Apple; each release's notes state its notarization
> status. Sentry ships outside the Mac App Store by necessity, not choice —
> it reads low-level power and thermal interfaces (`libIOReport`,
> `IOHIDEventSystemClient`) that do not exist inside the App Sandbox the
> App Store requires.

**iPhone & Apple Watch:** the companion apps are built from this same repo
(`SentryMobile`, `SentryWatch`) — the watch app installs automatically with
the iPhone app. Open Sentry on the iPhone while the Mac app is running on
the same Wi-Fi and they find each other over Bonjour; for away-from-home
access, scan the pairing QR code in **Settings ▸ Sync** on the Mac.

## What it does

**On the Mac** — a menu bar readout (monochrome, layout-configurable) with a
themed dropdown; a Dashboard of live charts backed by a GRDB history store
with tiered rollups; Protection Insights (battery health trend with a
degradation ETA, thermal cool-down estimates, energy use in kWh by day /
week / month); alert rules with history; keep-awake with process-aware mode
(hold until a named process exits); fan RPM readout everywhere and real fan
*control* on Apple Silicon behind an explicitly-installed root helper
(`SentryFanDaemon` — SMC writes live in that binary and nowhere else); a
custom theme editor with WCAG contrast checking on top of 15 built-in
themes.

**Companions** — an iPhone app and a three-page Watch app (overview,
keep-awake, agent activity — with a kill-switch resume path and its own Siri
intents), both fed over local-network sync (Bonjour) and, away from home, a
TLS-PSK listener the user pairs with a QR code. Reconnection is
keepalive-backed and sleep/wake-aware, and reconnects prefer the
last-connected Mac rather than whichever one answers first. There is
deliberately **no cloud**: your Mac's data goes to your phone and your
watch, never to a server. Shortcuts/Siri work locally, in-process, with no
network hop.

**Keep-awake** goes beyond a duration: conditional release (battery below
%, sustained CPU above %, while a named app or process runs, while a
download is active, on a schedule) — `PowerControlService`'s
`ReleaseCondition`.

**For agents and scripts** — an MCP server in two transports (stdio via
`SentryMCP` for Claude Desktop/Code/Cursor; optional LAN HTTP gated by an
API key), with per-tool toggles, **per-client** rate limiting, and
confirmation gates on write tools, all in Settings ▸ AI Access. Past
permissions, this is a real agent *manager*: `preflight_check` returns a
structured proceed/caution/wait/do-not-start verdict with reasons and a
wait estimate before an agent starts heavy work; `get_agent_capacity` shows
what other sessions are active so two agents don't contend; per-session
resource attribution (`get_session_resource_report`) reports what a
session actually cost in battery, thermals, and awake time; guardrails
(battery floor, quiet hours, thermal auto-revoke) and a kill switch —
global or per-client — keep an agent from running the Mac hot while nobody's
watching, including `CaffeinateArbitrator`'s enforcement against a coding
agent's own external `caffeinate` process, not just Sentry's own keep-awake.
The `sentryctl` CLI (`check`, `wait`, `status`, `sessions`, `stop
<client>`, `session-report`, streaming `watch`, `statusline` for
tmux/Starship prompts, `hook pretooluse` for Claude Code's `PreToolUse`
gate) mirrors the same controls from the shell — including a packaged
Claude Code plugin bundle (MCP registration, the hook, and a
`subagentStatusLine` script) under
[`integrations/claude-code/plugin/`](integrations/claude-code/plugin/README.md).
Copy-pasteable configs live in
[`docs/integrations/`](docs/integrations/README.md).

## Building from source

The Xcode project is generated from [`project.yml`](project.yml) via
[XcodeGen](https://github.com/yonaskolb/XcodeGen) — `Sentry.xcodeproj` itself
is not committed, so text diffs stay reviewable.

```sh
brew install xcodegen   # once
xcodegen generate       # after cloning, or after editing project.yml
open Sentry.xcodeproj
```

Or build, install to /Applications, and (re)launch in one step:

```sh
./run.sh
```

Keep clones **outside iCloud-synced folders** (e.g. `~/Developer`, not
`~/Documents`): iCloud's FileProvider xattrs break codesign, its eviction
breaks git under disk pressure, and both have burned real hours here.
Derived data should also live outside the repo; `run.sh` handles this and
resolves `DEVELOPER_DIR` itself (preferring Xcode-beta if installed).

Targets: `Sentry` (menu bar app, builds `Sentry.app`), `SentryKit` (shared
models/services; separate macOS, iOS, and watchOS variants), `SystemMetricsKit`
(macOS collectors), `SentryMobile` (iOS companion), `SentryWatch` (watchOS
app) and `SentryWatchWidgetExtension` (complication),
`SentryWidgetExtension` (iOS home/lock-screen widget),
`SentryWidgetExtension_macOS` (desktop widget, fed live by the menu bar
app), `SentryMCP` (MCP stdio server), `SentryCLI` (builds `sentryctl`),
`SentryFanDaemon` (root fan helper), `SentryTests`.

Debug builds need no certificates at all; the strict Developer ID settings
are scoped to the Release configuration via the `DeveloperIDSigned` target
template in `project.yml`.

> Desktop widgets note: the macOS widget builds and is embedded, but macOS
> only lists widgets from apps signed with a real team identity. Add an
> Apple ID in Xcode → Settings → Accounts and set it as the project's team
> to make the widget appear in the gallery.

## Using the CLI and MCP

`SentryMCP` and `sentryctl` are copied into `Sentry.app/Contents/MacOS/` —
they link `SentryKit.framework` and can only resolve it from inside the
bundle, so that is where to invoke them from:
`/Applications/Sentry.app/Contents/MacOS/sentryctl check`.

Both reach the app over an XPC Mach service, brokered by a bundled
LaunchAgent registered from Settings ▸ AI Access ▸ Command-Line Access
(code-signature peer verification, `SentryMCPBridge`). Registration needs a
real code signature — on an ad-hoc-signed debug build, `SMAppService`
refuses and the tools fail with an error naming exactly that.
[`docs/integrations/README.md`](docs/integrations/README.md) documents the
one-time enable step and has copy-pasteable configs for Claude Desktop,
Claude Code, and Cursor.

## Privacy

Everything stays on your devices. The full policy — what is collected,
where it lives, and how to delete it — is
[`docs/privacy-policy.md`](docs/privacy-policy.md).

## Contributing

Issues and pull requests are welcome — see
[`CONTRIBUTING.md`](CONTRIBUTING.md) for how the project is laid out, how
to run the test suite, and what a good PR looks like. Maintainers cutting a
release should follow [`docs/release-checklist.md`](docs/release-checklist.md)
and run `scripts/release.sh`.

## License

Sentry is open source under the [MIT License](LICENSE), © Malek Swilam &
Aniketh Bandlamudi. Bundled open-source dependencies are acknowledged in
[`docs/third-party-licenses.md`](docs/third-party-licenses.md).
