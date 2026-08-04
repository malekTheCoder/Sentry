# Sentry 

A macOS menu bar system monitor with iPhone and Apple Watch companions,
remote access over the local network or a VPN, sleep-prevention control from
any of the three, and an AI-agent (MCP) integration layer.

By Malek Swilam & Aniketh Bandlamudi.

Private / proprietary — all rights reserved. Not licensed for reuse; see
[`LICENSE`](LICENSE). Bundled open-source dependencies are acknowledged in
[`docs/third-party-licenses.md`](docs/third-party-licenses.md).

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

**Companions** — an iPhone app (One Dark design language, a first-run
onboarding flow, full Dynamic Type support) and a three-page Watch app
(overview, keep-awake, agent activity — with a kill-switch resume path and
its own Siri intents), both fed over local-network sync (Bonjour) and, away
from home, a TLS-PSK listener the user pairs with a code. Reconnection is
keepalive-backed and sleep/wake-aware, and reconnects prefer the
last-connected Mac rather than whichever one answers first. There is
deliberately **no CloudKit**: the `StatsTransport` seam it was designed for
has no CloudKit conformer, and the local/TLS-PSK pair already covers the
actual need without an Apple-hosted copy of the data. macOS itself gets a
first-run welcome popover, and Shortcuts/Siri work locally, in-process, with
no network hop — `Sentry/Intents/SentryMacIntents.swift`.

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

**Monetization state** — free/Pro feature cut is implemented (`ProGate`);
the license *verification* half exists (Ed25519-signed license blobs,
offline grace, `LicenseProEntitlementStore`) and stops at a documented
activation seam. The checkout/vendor half (and the production keypair) is
deliberately not built — it needs accounts only the owner can create.

## Building

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

The app's product/display name is **Sentry**; the code, targets, and
bundle identifiers keep the Sentry name.

Targets: `Sentry` (menu bar app, builds `Sentry.app`), `SentryKit` (shared
models/services; separate macOS, iOS, and watchOS variants), `SystemMetricsKit`
(macOS collectors), `SentryMobile` (iOS companion), `SentryWatch` (watchOS
app) and `SentryWatchWidgetExtension` (complication),
`SentryWidgetExtension` (iOS home/lock-screen widget),
`SentryWidgetExtension_macOS` (desktop widget, fed live by the menu bar
app), `SentryMCP` (MCP stdio server), `SentryCLI` (builds `sentryctl`),
`SentryFanDaemon` (root fan helper), `SentryTests`.

## Using the CLI and MCP

`SentryMCP` and `sentryctl` are copied into `Sentry.app/Contents/MacOS/` —
they link `SentryKit.framework` and can only resolve it from inside the
bundle, so that is where to invoke them from:
`/Applications/Sentry.app/Contents/MacOS/sentryctl check`.

Both reach the app over an XPC Mach service, brokered by a bundled
LaunchAgent registered from Settings ▸ AI Access ▸ Command-Line Access
(code-signature peer verification, `SentryMCPBridge`). That registration
step needs a real code signature: **on an ad-hoc-signed debug build (no
Developer ID certificate installed), `SMAppService` refuses to register the
agent, and `sentryctl`/`SentryMCP` fail with an honest error naming exactly
that** rather than a generic "couldn't connect." Once a Developer ID
certificate exists and the app is signed with it, the same flow registers
for real — [`docs/integrations/README.md`](docs/integrations/README.md)
documents the one-time enable step.

Localization: all user-facing strings route through String Catalogs
(~900 keys across six catalogs, English-only on purpose — translations are
a quality decision for a human, not a build step).

> Desktop widgets note: the macOS widget builds and is embedded, but macOS
> only lists widgets from apps signed with a real team identity. Add an
> Apple ID in Xcode → Settings → Accounts and set it as the project's team
> to make the widget appear in the gallery.

## Before the first release

- [ ] Generate the Sparkle EdDSA key pair and replace the `SUPublicEDKey`
      placeholder — see [`docs/sparkle-release-signing.md`](docs/sparkle-release-signing.md).
      **Back the private key up offline**: losing it permanently orphans every
      installed copy, with no recovery path.
- [ ] Create a **Developer ID Application** certificate and verify the
      Release signing configuration end to end. (Team membership and an
      Apple Development certificate exist and have signed real builds; the
      Developer ID certificate specifically does not yet.)
- [ ] Notarize and staple a DMG, and confirm it passes
      `spctl -a -vvv -t install`.
- [ ] Publish `appcast.xml` to the feed URL baked into the app
      (`https://malekthecoder.github.io/Sentry/appcast.xml`). That URL is
      compiled into every shipped binary and cannot be changed on copies
      already installed — rename the GitHub account or repo *before* the first
      release, never after.
- [ ] Verify the SMAppService/command-line-bridge flow end to end once a
      Developer ID certificate exists — it's implemented and merged, but has
      only run under an ad-hoc/Apple Development signature so far (see
      "Using the CLI and MCP" above).
- [ ] Decide the licensing checkout vendor and build the
      `LicenseActivationClient` conformer against it; generate the production
      Ed25519 keypair offline.
- [ ] Regenerate the marketing screenshots; the committed set predates the
      visual redesign (some individual assets — Insights, Watch — have been
      refreshed since; a full pass hasn't).
- [ ] Publish [`docs/privacy-policy.md`](docs/privacy-policy.md) at a public
      HTTPS URL — see
      [`docs/privacy-policy-publishing.md`](docs/privacy-policy-publishing.md).
      Both the Mac and iPhone About screens link to it and currently say so
      isn't live yet.
- [ ] Resolve the product name. "Sentry" collides with Sentry.io
      (application monitoring — same developer-tools audience this app's
      agent-manager feature targets). Cheap to change now; the Sparkle feed
      URL noted above becomes permanent the moment it's first published, and
      the App ID/App Group/iCloud container identifiers become permanent the
      moment Aniketh registers them.
- [ ] Draft a real EULA. `LICENSE` is "all rights reserved" only — it
      prevents the worst outcome (no license at all) but isn't a substitute
      for terms covering what a Pro purchase grants, refunds, and liability.

## Releasing

Sentry is distributed outside the Mac App Store, as a notarized Developer ID
build. That is forced, not chosen: the app reads `libIOReport.dylib` and the
private `IOHIDEventSystemClient` API, neither of which exists inside the App
Sandbox that the App Store requires. `Sentry/Sentry.entitlements` says so in
its header, and is one key long — the reasoning for everything it *doesn't*
claim is written there too.

Debug builds are unaffected by any of this and still need no certificates at
all; the strict settings are scoped to the Release configuration via the
`DeveloperIDSigned` target template in `project.yml`.

```sh
scripts/release.sh                  # archive → export → verify → dmg → notarize → staple
scripts/release.sh --skip-notarize  # everything up to submission
```

Prerequisites (a `Developer ID Application` certificate, `create-dmg`, and a
stored `notarytool` credential) are listed in that script's header, and it
refuses to start until all of them are present.

**This pipeline has never been run end to end.** It was written before any
signing identity existed on a build machine, so every step from
`xcodebuild archive` onward is unverified. See the honesty note at the top
of `scripts/release.sh`.
