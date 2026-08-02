# Sentry 

A macOS menu bar system monitor with iPhone and Apple Watch companions,
remote access over the local network or a VPN, sleep-prevention control from
any of the three, and an AI-agent (MCP) integration layer.

Private / proprietary — all rights reserved. Not licensed for reuse.

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

**Companions** — an iPhone app (One Dark design language) and a three-page
Watch app (overview, keep-awake, agent activity), both fed over local-network
sync (Bonjour) and, away from home, a TLS-PSK listener the user pairs with a
code. There is deliberately **no CloudKit**: the `StatsTransport` seam it
was designed for has no CloudKit conformer, and the local/TLS-PSK pair
already covers the actual need without an Apple-hosted copy of the data.

**For agents and scripts** — an MCP server in two transports (stdio via
`MacStatMCP` for Claude Desktop/Code/Cursor; optional LAN HTTP gated by an
API key), with per-tool toggles, a rate limit, and confirmation gates on
write tools, all in Settings ▸ AI Access; and a `macstat` CLI (`check`,
`wait`, `status`, `session-report`, streaming `watch`, `statusline` for
tmux/Starship prompts). Copy-pasteable configs live in
[`docs/integrations/`](docs/integrations/README.md).

**Monetization state** — free/Pro feature cut is implemented (`ProGate`);
the license *verification* half exists (Ed25519-signed license blobs,
offline grace, `LicenseProEntitlementStore`) and stops at a documented
activation seam. The checkout/vendor half (and the production keypair) is
deliberately not built — it needs accounts only the owner can create.

## Building

The Xcode project is generated from [`project.yml`](project.yml) via
[XcodeGen](https://github.com/yonaskolb/XcodeGen) — `MacStat.xcodeproj` itself
is not committed, so text diffs stay reviewable.

```sh
brew install xcodegen   # once
xcodegen generate       # after cloning, or after editing project.yml
open MacStat.xcodeproj
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
bundle identifiers keep the MacStat name.

Targets: `MacStat` (menu bar app, builds `Sentry.app`), `MacStatKit` (shared
models/services; separate macOS, iOS, and watchOS variants), `SystemMetricsKit`
(macOS collectors), `MacStatMobile` (iOS companion), `MacStatWatch` (watchOS
app) and `MacStatWatchWidgetExtension` (complication),
`MacStatWidgetExtension` (iOS home/lock-screen widget),
`MacStatWidgetExtension_macOS` (desktop widget, fed live by the menu bar
app), `MacStatMCP` (MCP stdio server), `MacStatCLI` (builds `macstat`),
`SentryFanDaemon` (root fan helper), `MacStatTests`.

## Using the CLI and MCP

`MacStatMCP` and `macstat` are copied into `Sentry.app/Contents/MacOS/` —
they link `MacStatKit.framework` and can only resolve it from inside the
bundle, so that is where to invoke them from:
`/Applications/Sentry.app/Contents/MacOS/macstat check`.

Both reach the app over an XPC Mach service. On current `main` that service
is not yet registered with launchd — the CLI fails with an error saying so —
and the fix (a bundled LaunchAgent registered from Settings ▸ AI Access ▸
Command-Line Access, with code-signature peer verification) is implemented
and verified end to end on the **`fix/xpc-launchagent`** branch, awaiting
review. Once merged, [`docs/integrations/README.md`](docs/integrations/README.md)
documents the one-time enable step.

Localization: all user-facing strings route through String Catalogs
(~780 keys across six catalogs, English-only on purpose — translations are
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
- [ ] Merge and re-verify `fix/xpc-launchagent` under the Developer ID
      identity (its peer gate and SMAppService flow are verified under an
      Apple Development signature; same team, but say so only after seeing it).
- [ ] Decide the licensing checkout vendor and build the
      `LicenseActivationClient` conformer against it; generate the production
      Ed25519 keypair offline.
- [ ] Regenerate the marketing screenshots; the committed set predates both
      the rename to Sentry and the visual redesign.

## Releasing

Sentry is distributed outside the Mac App Store, as a notarized Developer ID
build. That is forced, not chosen: the app reads `libIOReport.dylib` and the
private `IOHIDEventSystemClient` API, neither of which exists inside the App
Sandbox that the App Store requires. `MacStat/MacStat.entitlements` says so in
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
