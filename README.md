# MacStat

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

Targets: `MacStat` (menu bar app), `MacStatKit` (shared models/services,
macOS+iOS), `SystemMetricsKit` (macOS collectors), `MacStatMobile` (iOS
companion), `MacStatWidgetExtension` (iOS home/lock-screen widget),
`MacStatWidgetExtension_macOS` (desktop widget, fed live by the menu bar
app), `MacStatMCP` (MCP stdio server), `MacStatCLI`, `MacStatTests`.

> Desktop widgets note: the macOS widget builds and is embedded, but macOS
> only lists widgets from apps signed with a real team identity. Add an
> Apple ID (free personal team) in Xcode → Settings → Accounts and set it as
> the project's team to make the widget appear in the gallery.
