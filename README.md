# Sentry (codebase: MacStat)

A macOS menu bar system monitor with iPhone and Apple Watch companions,
remote access over the local network or a VPN, sleep-prevention control from
any of the three, and an AI-agent (MCP) integration layer.

Private / proprietary — all rights reserved. Not licensed for reuse.

**Status:** feature-complete for a first release; release engineering in
progress. The metric collection, history, alerting, menu bar, dashboard,
Protection Insights, fan RPM readout, iPhone app, Watch app, widgets, MCP
server, and CLI are all built and tested. What remains before shipping is
signing, notarization, and the Sparkle update channel — see the checklist
below.

There is **no CloudKit sync**, despite what earlier drafts of the plan
assumed. Mac↔iPhone sync runs over the local network (Bonjour) and, away
from home, over a second TLS-PSK listener the user pairs with a code; both
are documented in `MacStatKit/LocalSync/`. A CloudKit transport was never
built, and the `StatsTransport` seam it was designed for has no CloudKit
conformer.

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

`run.sh` also documents the two quirks of building from this machine: the
repo lives in iCloud-synced `~/Documents`, so derived data must live outside
the repo (codesign rejects FileProvider xattrs), and `DEVELOPER_DIR` must
point at an installed Xcode (`run.sh` resolves this itself now, preferring Xcode-beta if present).

The app's product/display name is **Sentry**; the code, targets, and
bundle identifiers keep the MacStat name.

Targets: `MacStat` (menu bar app, builds `Sentry.app`), `MacStatKit` (shared
models/services; separate macOS, iOS, and watchOS variants), `SystemMetricsKit`
(macOS collectors), `MacStatMobile` (iOS companion), `MacStatWatch` (watchOS
app) and `MacStatWatchWidgetExtension` (complication),
`MacStatWidgetExtension` (iOS home/lock-screen widget),
`MacStatWidgetExtension_macOS` (desktop widget, fed live by the menu bar
app), `MacStatMCP` (MCP stdio server), `MacStatCLI`, `MacStatTests`.

## Before the first release

- [ ] Generate the Sparkle EdDSA key pair and replace the `SUPublicEDKey`
      placeholder — see [`docs/sparkle-release-signing.md`](docs/sparkle-release-signing.md).
      **Back the private key up offline**: losing it permanently orphans every
      installed copy, with no recovery path.
- [ ] Sign into an enrolled Apple ID in Xcode and create a Developer ID
      Application certificate, then verify the Release signing configuration
      end to end (it is configured but has never been exercised — this machine
      has no certificates).
- [ ] Notarize and staple a DMG, and confirm it passes
      `spctl -a -vvv -t install`.
- [ ] Publish `appcast.xml` to the feed URL baked into the app
      (`https://malekthecoder.github.io/Sentry/appcast.xml`). That URL is
      compiled into every shipped binary and cannot be changed on copies
      already installed — rename the GitHub account or repo *before* the first
      release, never after.
- [ ] Regenerate the marketing screenshots; the committed set predates both
      the rename to Sentry and the visual redesign.

`MacStatMCP` and `macstat` (the `MacStatCLI` product) are copied into
`Sentry.app/Contents/MacOS/` — they link `MacStatKit.framework` and can only
resolve it from inside the bundle, so that is where to invoke them from:
`/Applications/Sentry.app/Contents/MacOS/macstat check`.

> Desktop widgets note: the macOS widget builds and is embedded, but macOS
> only lists widgets from apps signed with a real team identity. Add an
> Apple ID (free personal team) in Xcode → Settings → Accounts and set it as
> the project's team to make the widget appear in the gallery.

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

**This pipeline has never been run end to end.** It was written on a machine
with zero signing identities, so every step from `xcodebuild archive` onward is
unverified. See the honesty note at the top of `scripts/release.sh`.
