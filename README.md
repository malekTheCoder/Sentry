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

Or build from the command line:

```sh
xcodebuild -project MacStat.xcodeproj -scheme MacStat -configuration Debug \
  -destination 'platform=macOS' build
```

Targets: `MacStat` (menu bar app), `MacStatKit` (shared models/services,
macOS+iOS), `SystemMetricsKit` (macOS collectors), `MacStatMobile` (iOS
companion), `MacStatWidgetExtension` (iOS widget), `MacStatMCP` (MCP stdio
server, placeholder), `MacStatTests`.
