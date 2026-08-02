# Sentry (codebase: MacStat)

A macOS menu bar system monitor with an iPhone companion app, CloudKit sync,
remote sleep-prevention control, and an AI-agent (MCP) integration layer.

Private / proprietary — all rights reserved. Not licensed for reuse.

**Status:** early development (Phase 0).

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
point at Xcode-beta.

The app's product/display name is **Sentry**; the code, targets, and
bundle identifiers keep the MacStat name.

Targets: `MacStat` (menu bar app, builds `Sentry.app`), `MacStatKit` (shared models/services,
macOS+iOS), `SystemMetricsKit` (macOS collectors), `MacStatMobile` (iOS
companion), `MacStatWidgetExtension` (iOS home/lock-screen widget),
`MacStatWidgetExtension_macOS` (desktop widget, fed live by the menu bar
app), `MacStatMCP` (MCP stdio server), `MacStatCLI`, `MacStatTests`.

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
