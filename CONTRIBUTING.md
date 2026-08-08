# Contributing to Sentry

Thanks for your interest in Sentry! Issues and pull requests are welcome.

## Getting set up

```sh
git clone https://github.com/malekTheCoder/Sentry.git
cd Sentry
brew install xcodegen
xcodegen generate
open Sentry.xcodeproj
```

Two things that will save you real time:

- **Clone outside iCloud-synced folders** (`~/Developer`, not `~/Documents`
  or Desktop). iCloud's FileProvider xattrs break codesign, and its file
  eviction can corrupt a git checkout under disk pressure.
- **`Sentry.xcodeproj` is generated, not committed.** All project structure
  lives in [`project.yml`](project.yml); edit that and re-run
  `xcodegen generate`. Never commit the `.xcodeproj`. The same applies to
  `SentryMobile/Info.plist` and other generated plists — set Info-plist keys
  in `project.yml`'s `info:` blocks or your edits will evaporate on the next
  generate.

Debug builds need no certificates or Apple Developer account. `./run.sh`
builds, installs to `/Applications`, and relaunches the app in one step.

## Running the tests

The macOS unit suite is the main gate:

```sh
xcodegen generate
xcodebuild -project Sentry.xcodeproj -scheme Sentry -destination 'platform=macOS' test
```

If you touch shared code (`SentryKit`, `SystemMetricsKit`), also confirm the
iOS and watchOS targets still build:

```sh
xcodebuild -project Sentry.xcodeproj -scheme SentryMobile -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Sentry.xcodeproj -scheme SentryWatch  -destination 'generic/platform=watchOS Simulator' build
```

## What a good PR looks like

- **Green tests**, and new tests for new behavior — especially for anything
  in `SentryKit` or `SystemMetricsKit`, which are pure and easy to test.
- **Honest UI**: this project cares about never showing fabricated data. A
  metric that can't be read shows as absent, not as zero; charts don't
  extrapolate beyond what was measured. Please keep that bar.
- **Small and focused.** One change per PR; refactors separate from
  behavior changes.
- **Security-sensitive areas** — `SentryFanDaemon` (root helper, the only
  code allowed to write to the SMC), the MCP server, and the sync
  listeners — get extra scrutiny. Explain your reasoning in the PR
  description.

## Reporting issues

Include your macOS version, hardware (Apple Silicon or Intel), the app
version (About screen), and — for sync issues — whether both devices are on
the same network. Logs from Console.app filtered to subsystem
`dev.malekswilam.sentry` are often the fastest path to a diagnosis.
