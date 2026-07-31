# PROGRESS

Running log of launch-readiness work, kept **in-repo** so both machines see
it (the `/Users/malekswilam/.../PROGRESS.md` referenced by the Launch
Readiness Master Prompt lives outside this repo on the other machine and
cannot be seen from here — if these two logs drift, reconcile them
manually).

## 2026-07-31 — machine `ankthba` (Sentry rebrand machine)

### Repo reconciliation
- Merged the diverged mains: this machine's Sentry rebrand / Liquid Glass
  redesign / one-window shell / iOS glass pass × the other machine's
  watchOS app + complication, localization (String Catalogs), and Location
  Log. Merge commit `eb6dea4`, pushed. Conflict resolutions of note:
  - `SettingsView`: kept the one-window two-pane shell, added the Location
    pane (green chip, `location.fill`), adopted `String(localized:)`
    wrappers, threaded `locationService` through `MainWindowView`'s
    Settings tab (the old `SettingsWindowController`/`HistoryWindowController`
    stay deleted — their param additions were ported, not resurrected).
  - Localization × rename: wherever the localization pass had wrapped a
    string the rebrand renamed, the resolution is the **Sentry** text inside
    the localized wrapper.
- Verified post-merge: macOS build + full unit suite green, iOS Simulator
  build green, watchOS Simulator build green.

### Launch Readiness Master Prompt — Section 1 findings (reported to user)
- iOS (`MacStatMobile`): no private-API exposure — `SystemMetricsKit` is
  macOS-only and not in any iOS target's graph. Clean for real TestFlight.
- macOS (`Sentry.app`): two private-API surfaces, both dlopen/dlsym-gated:
  `IOReportBridge` (libIOReport — GPU/ANE/CPU power) and `ThermalCollector`
  (IOHIDEventSystemClient — per-sensor SoC temps).
- Recommendation on the table (user decision pending): iOS → TestFlight;
  Mac → Developer ID + notarization outside the Mac App Store (Path 2),
  because the app's differentiators sit directly on those private APIs.

### Blocked on the user (cannot be automated, per master prompt §0)
- Apple Developer Program enrollment ($99/yr, license agreement, 2FA).
- Everything in master prompt §§2–3 and 5–6 (signing, App IDs,
  capabilities, CloudKit transport, TestFlight upload) waits on that.
- Free personal team alternatively unblocks: macOS widget-gallery
  registration, local Developer-ID-style testing — but not TestFlight.

### Section 4 correctness audit — COMPLETE (six parallel sub-agents + integration)

Verified after integration: macOS build + full test suite, iOS build,
watchOS build all green. Highlights (every fix has file-level detail in the
commit message):

- **Collectors:** per-process CPU was ~41.7× underreported on Apple Silicon
  (Mach ticks read as ns — fixed with timebase conversion); guaranteed
  eventual crash on long-uptime Macs (`UInt32` trap on per-core tick
  counters — fixed with `bitPattern:`); battery health silently absent on
  current macOS (IORegistry key moved into `BatteryData` — fallback added);
  fabricated "0.0 W" system power when telemetry key absent (now nil);
  32-bit wrap delta off-by-one (fixed; stale test expectation corrected).
- **Persistence:** retention-boundary rollup overwrite permanently
  corrupted the oldest hourly bucket every hour and the keep-forever daily
  tier every day (sample-count guards added to both upserts); unbounded
  buffer growth when the DB fails to open (drop-and-log now); missing
  metric-leading indexes on both rollup tiers (additive v4 migration);
  first-ever RollupJob test suite (8 tests).
- **Power/alerts:** stale expiry-timer race could release a *newer*
  assertion (generation token added); `duration ≤ 0` minted an indefinite
  never-sleep hold (now releases); phantom "Delivered" log entries burned
  rate-cap slots for unwired actions (guarded); notification-auth denial
  now logged. 8 new regression tests.
- **Mac UI:** wrong app name in Location Services recovery instructions;
  Alerts pane claimed working actions "do nothing"; dead code from three
  redesigns removed; preview strip was illegible for fixed-dark themes and
  unfaithful to the monochrome renderer (both fixed); inert "Check for
  updates daily" and "Match system appearance" controls removed with honest
  disclosure; Energy card's "Today" no longer freezes for the app's
  lifetime (periodic reload).
- **MCP security:** API-key regeneration now actually revokes (per-request
  key resolution); 1 MiB body cap + connection close on the remote HTTP
  server (was unauthenticated unbounded memory growth → remote crash);
  start/stop race that could leave the LAN port bound after disable
  (generation guard); keep_awake duration clamped (non-finite input minted
  an indefinite hold); confirmation-dialog text sanitized (caller-chosen
  strings could inject misleading copy); denial floods can no longer erase
  the audit log; rate limiter locked; subscription pump backs off; remote
  key cleared on disable.
- **Mobile/watch/location:** phone widget writer honesty (demo flag now
  real, ~5,700 reloads/day throttled to budget); watch complication
  transfers capped ≤48/day + system budget check; **Location Log privacy
  bugs fixed** — capture no longer auto-restarts after opt-out, and the
  last fix is cleared on disable so it stops broadcasting over LAN;
  mid-session Mac disconnect now reconnects automatically and shows an
  honest "connection lost" banner instead of claiming a live link;
  device freshness uses last-snapshot time; Sentry naming completed across
  iOS/watch/widgets (incl. iPhone home-screen display name).

### Known residuals (decisions/design work, deliberately not drive-by fixed)
- `LocalSyncServer` starts unconditionally and broadcasts telemetry +
  machine name unauthenticated on the LAN (strictly read-only; no control
  path). **Pre-beta decision needed:** settings gate (default off?) and/or
  pairing secret, and a neutral Bonjour instance name.
- `alert_log` records `delivered: true` for notification actions when
  authorization is denied (async outcome; needs a design, not a patch).
- Successful `resources/subscribe` consumes the whole default MCP rate
  budget (20/min); NSAlert confirmation dialogs can stack; denial floods
  are free main-thread pressure.
- `ModuleCardStack`/`MetricCard`/`SparklineChart` are dead views hosting
  two live helpers — needs a relocation-then-delete pass.
- Watch/iOS `.xcstrings` catalogs still contain stale "MacStat" *keys*
  (harmless — unused after the rename; regenerate via Xcode export).

### Environment notes for future agents on this machine
- Repo sits in iCloud-synced `~/Documents` — DerivedData must live outside
  the repo (`~/Library/Developer/MacStat-DerivedData*`), and iCloud sync
  spawns `file 2.swift` duplicates that break builds; delete them.
- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` is
  required for all xcodebuild/simctl invocations (`xcode-select` points at
  CommandLineTools; changing it needs the user's password).
- `./run.sh` builds, installs to `/Applications/Sentry.app`, and relaunches.

### Protection Insights (Pro feature) — engine, collector, UI, and wiring

New Pro-gated feature: a third main-window tab ("Insights") that turns this
Mac's own measured history and security posture into evidence-backed
recommendations, plus an explainable 0–100 Protection Score.

- **`MacStatKit/Insights/`** (pure, cross-platform, no I/O): `ProtectionInsight`
  model, `InsightCategory`/`InsightSeverity`/`InsightDomain`, `InsightContext`
  (everything a rule may read, all-value), `ProtectionInsightRule` protocol,
  `ProtectionInsightsEngine` running 44 rules across battery longevity,
  thermal, storage, memory, security, privacy, power habits, and maintenance,
  and `ProtectionScore` — start at 100, subtract every firing insight's
  `scoreImpact` from a fixed six-tier weight vocabulary (`InsightWeight`),
  clamp at 0, with per-category subscores and an honest "not enough data"
  state for categories with nothing to judge. `InsightSuppression` (dismiss/
  snooze) and `ProGate` (the free/paid cut — two full findings free, the rest
  locked to category+severity only, no strings withheld-but-obscured) live
  alongside it.
- **`SystemMetricsKit/Security/SecurityPostureCollector.swift`**: macOS-only,
  off-main-thread (dedicated `DispatchQueue`, not the cooperative pool),
  5-minute TTL-cached collector reading FileVault/SIP/Gatekeeper/firewall/
  auto-update/screen-lock/sharing-service posture via subprocess calls
  (`fdesetup`, `csrutil`, `spctl`, `socketfilterfw`, `defaults read`,
  `netstat`). Every probe that fails, times out, or prints something
  unrecognized degrades to `.unknown` — never guessed as off.
  `SecurityPostureParser` (pure parsing, no subprocess) is the tested half.
- **UI (`MacStat/Insights/`)**: `InsightsView`/`InsightsViewModel` (same
  two-path shape as `DashboardViewModel` — cheap `ingest(_:)` every snapshot
  tick, expensive `refresh()` only on window-appear/explicit Refresh, no
  timer), `ProtectionScoreCard`, `CategoryBreakdownCard`, `InsightRowView`
  (+ `LockedInsightRowView`), `ProUpsellCard`. Wired into `MainTab.insights`
  in `MainWindowView` between Dashboard and Settings.
- **Composition root**: `AppDelegate` now constructs `ProEntitlementStore`
  (the local, no-StoreKit developer-override entitlement check) and
  `SecurityPostureCollector` as app-lifetime instances, builds
  `insightsViewModel` the same lazy-singleton way as `dashboardViewModel`
  (same `historyStore`, wired into the snapshot loop's `ingest`, theme and
  settings propagation in `applySettings`, `cancelRefresh()` on the window's
  `onHide` so a refresh in flight for a closed window isn't wasted work), and
  passes its `AnyView` into `MainWindowView`'s `insights:` parameter.
- **Tests**: `MacStatTests/ProtectionInsightsEngineTests.swift` — rule
  fire/don't-fire boundaries (FileVault on/off/unknown, firewall severity
  following actual exposure, screen-lock-delay threshold, deep-discharge
  advisory/warning tiers, hardened-baseline requiring all four, posture-
  unknown honesty rule), engine invariants (evidence-free insights dropped,
  duplicate ids deduped, prioritisation order), suppression/snooze/dismiss
  filtering (active vs. expired snooze, malformed nil-`until` snooze treated
  as expired not indefinite, dismissals never expire), score determinism/
  order-independence/monotonicity/clamping/no-data categories,
  `SecurityPostureParser` parsing including malformed and empty input
  (→ `.unknown`/`nil`, never a guess), and the Pro gating cut (free tier sees
  exactly the top two findings in full, everything else locked to
  category+severity, unlocked sees everything).

**NOT BUILT OR TESTED: no Swift toolchain was available in the environment
where this was written; needs `xcodegen generate` + a full build + test run
on the Mac.** Every cross-file reference (rule inventory names, `ProtectionInsight`
field names, `ProEntitlementProviding`/`SecurityPostureProviding` shapes,
UI-to-view-model bindings) was verified by hand against the defining files,
but hand-verification is not a compiler. A human must confirm on a real
Xcode build before this merges: the project actually compiles across all
three targets (`MacStat`, `MacStatKit_macOS`, `SystemMetricsKit`), the new
test file runs and passes, the Insights tab renders correctly at runtime
(theme, layout, the ring/score card, locked-row paywall visuals), and that
`SecurityPostureCollector`'s subprocess calls behave as expected on a real
Mac (this was never exercised against actual `fdesetup`/`csrutil`/etc.
output beyond the parser's unit tests).
