# Localization coverage audit

Infrastructure only. This pass routes user-facing strings through the
localization machinery and gives every UI target a string catalog to resolve
against. It adds **zero translations** — that is deliberate and must stay
that way: machine translations in a paid product are a quality risk nobody
here can review, so every catalog carries English keys only.

Scope audited: `MacStat/`, `MacStatMobile/`, `MacStatWatch/`,
`MacStatWidget/` (plus `MacStatWatchWidget/`, which the widget audit made
obviously incomplete without). `MacStatKit/` was touched only where reading
it was needed to classify a string; kit-rooted findings are recorded below
as deferred, not fixed.

**This branch was not built.** The task explicitly forbade `xcodebuild` and
`xcodegen`, so no compile, no tests, and no Xcode catalog sync ran. Every
modified Swift file passes `swiftc -parse` (syntax only — not type
checking), and every `.xcstrings` file is valid JSON in the same shape as
the existing catalogs, but the first real build is the actual verification.

## What the audit looked for

1. `Text(someVariable)` where the variable holds an English literal from a
   non-localized source — computed properties returning `"Charging"`,
   `switch`es over enums returning display names. These bypass
   `LocalizedStringKey` entirely: only *literals* at a `LocalizedStringKey`
   parameter get extracted; a `String`-typed variable renders verbatim.
2. Literals passed to `String`-typed parameters (`label:`, `title:`,
   `value:` on row helpers) — same bypass, one call further out.
3. Ternaries of two bare literals (`flag ? "On" : "Off"`) — the expression
   is `String`, so even at an API with a `LocalizedStringKey` overload the
   non-localizing `String` overload wins.
4. Sentences assembled by `+` / `+=` / fragment interpolation
   (unlocalizable word order), and `String(format:)` carrying English words.

## What was fixed (~460 call sites)

House style throughout: `String(localized:)` at the literal site, matching
the pattern already established in `ProUpsellCard`/`SettingsView`.
Interpolated values are pre-formatted to `String` first so every catalog
key carries plain `%@` placeholders — the shape the existing catalog
already uses (`"%@ health · %@ cycles"`).

### MacStat (Mac app)

- `App/MainWindow.swift` — `MainTab.title` (Dashboard/Insights/Settings).
- `App/AppDelegate.swift` — the `"This Mac"` device-name fallback.
- `Dropdown/SleepControlCard.swift` — trigger picker labels, menu labels,
  `AwakeMode` short/long labels and explanations, option-menu titles,
  value-row labels ("Ends"/"Mode"/"Remaining"), accessibility labels and
  values, start-error messages. The `String`-ternary accessibility value
  was rebuilt as two whole `Text`s.
- `Dropdown/SystemVitals.swift` — every `VitalDetail` label, vital titles,
  level notes, status headlines and reasons, pressure/battery-state/adapter
  text helpers.
- `Dropdown/ModuleCards/ModuleCardStack.swift` and
  `Dashboard/DashboardGrid.swift` (deliberately kept byte-for-byte
  parallel, as their comments demand) — all `MetricDetailRow` labels,
  `"load %.2f"` → `"load %@"`, `"%@ procs"`, memory `"%@ of %@"`,
  pressure/Yes/No values, `"%@ pressure"` (was `+ " pressure"` glue),
  `PressureLevel.displayName`, fan rows.
- `Dropdown/MetricFormatting.swift` — `"up " + uptime` concatenation →
  one `"up %@"` key.
- `Dashboard/DashboardChart.swift` — stat sentences and accessibility
  range descriptions; the `String(format: "avg CPU %.0f%% …")` sentence now
  formats its numbers first and localizes the sentence as one key.
- `Dashboard/BatteryHealthTrendCard.swift` — forecast sentences.
- `Insights/InsightsView.swift` — "checked Ns ago" header captions.
- `Settings/SettingsView` panes:
  - `MenuBarPane.swift` — visibility-rule names, preview summaries, unit
    descriptions.
  - `AlertsPane.swift` — mode names, restore-defaults dialog (the inner
    `"1 rule"/"N rules"` ternary was a raw-`String` splice inside a
    localized `Text`), new-rule name and notification copy (localized at
    creation, like "Untitled"), global-limit values, history summary with
    explicit plural branches, history rows, `humanDuration` rebuilt from
    suffix-glued `"second\(s)"` into whole per-plural sentences (English
    output unchanged — `AlertsPaneFormattingTests` pins it), action
    titles/details, precondition names.
  - `ModulesPane.swift` — module subtitles.
  - `AIAccessPane.swift` — decision labels.
  - `FanControlPane.swift` — action messages, capability headlines/details,
    target/limits labels (English output unchanged —
    `FanControlServiceTests` pins it).
  - `SyncPane.swift` — `intervalLabel` plural branches (English output
    unchanged — `SyncPaneFormattingTests` pins "Every 1 second").
  - `MenuBarPreviewStrip.swift` — empty-layout accessibility description.
- `Settings/Panes/AlertsPane.swift:912` — the one *removal*: the generic
  condition summary was wrapped in `String(localized:)` producing the
  meaningless key `"%@ %@ %@"`. Unwrapped, with the same doc comment
  `AlertRuleDisplay` already carried for the identical decision on iOS;
  the key was dropped from the catalog.

### MacStatMobile (iPhone app)

- `Dashboard/VitalsLedger.swift` — ledger row labels, detail tuples,
  context words ("active"/"idle"/"free", thermal context), chart legend
  titles, CPU stat sentence.
- `Dashboard/MetricFormatting.swift` — pressure-level word forms.
- `Dashboard/BatteryHeroCard.swift` — state/time labels, detail labels.
- `Dashboard/SleepStatusCard.swift` — feedback strings ("Sending…",
  "Done.", "Not sent — %@"), mode labels, `AwakeMode.mobileShortLabel`.
- `History/HistoryTabView.swift` — "Battery health · %@" headline.
- `History/BatteryHealthTrendChart.swift` — accessibility range text.
- `Watch/WatchRelayManager.swift` — `awakeModeLabel` (rendered verbatim on
  the watch, so localized here on the phone whose locale the watch shares).
- `Intents/MacStatIntents.swift` — every Siri dialog string. The battery
  sentence built with `+=` fragments was rebuilt so each charging state is
  a whole localized sentence; trailing clauses remain appended fragments,
  each a whole localized phrase (see "left" list for the reasoning).

### MacStatWatch (watch app) — previously unlocalizable

- **New catalog: `MacStatWatch/Resources/Localizable.xcstrings`** (80
  keys). Before this file existed the target had no catalog at all, so
  nothing in it — literal or not — could ever localize.
- `Pages/OverviewPage.swift` — hero captions, thermal/memory chip labels,
  tile labels (the `Metric` model grew a `label` field so `id` stays a
  stable `ForEach` identity while the label localizes), accessibility
  labels.
- `ContentView.swift` — unavailable-page titles/details, command success
  sentences.
- `Pages/KeepAwakePage.swift`, `Pages/AgentActivityPage.swift` —
  accessibility labels, "tool call(s)" plural branches.
- `Intents/MacStatWatchIntents.swift` — every Siri dialog string, battery
  sentence rebuilt as whole sentences per charging state.

### MacStatWidget / MacStatWatchWidget — previously unlocalizable

- **New catalogs: `MacStatWidget/Resources/Localizable.xcstrings`** (18
  keys, shared by the iOS and macOS widget extension targets) **and
  `MacStatWatchWidget/Resources/Localizable.xcstrings`** (6 keys). A
  widget bundle resolves strings against its *own* catalog, not its host
  app's.
- `Views/LargeWidgetView.swift` — metric row labels, sleep label.
- `Views/MediumWidgetView.swift` — sleep/awake-mode captions.
- `Views/AccessoryWidgetViews.swift` — "CPU %@%%" stat fragment.
- `MacStatWidgetBundle.swift` — gallery description (a `String` property,
  so the `.description(_:)` call was taking the verbatim overload).
- `ComplicationView.swift` — "Charging"/"Mac" caption ternary.

### Catalog seeding and `project.yml`

Because no build ran, Xcode's automatic extraction could not sync the
catalogs. Every key introduced by the changes above was seeded manually
with `"extractionState": "manual"` + an English `stringUnit`, the exact
shape the existing 41 manual entries in the Mac catalog use (multi-
placeholder values use positional `%1$@` form, matching
`"%@ health · %@ cycles"`). Literal `%` in keys that also carry
placeholders is escaped as `%%` (`"Your Mac's battery is at %@%%,
charging"`), matching format-string semantics. For the three *new*
catalogs, plain `Text`/`Label`/`Button`/accessibility literals were seeded
too, since no build has ever extracted them. The first Xcode build will
reconcile states (manual → extracted) and pick up the few interpolated
`LocalizedStringKey` literals that were deliberately not hand-seeded (see
below).

`project.yml` needed no structural change — XcodeGen picks up `.xcstrings`
by extension from each target's existing `sources:` path (the same
mechanism its comments document for `PrivacyInfo.xcprivacy`). Comments were
added at the three targets so the mechanism stays discoverable.

## Found but deliberately left

Localization-adjacent, with the reasoning; file:line as of this branch.

- **`MacStat/Dropdown/SleepControlCard.swift:705` `assertionReason`** —
  dual-purpose string: UI caption on the active card *and* the reason
  handed to IOKit, where it lands in `pmset -g assertions`, power logs, and
  bug reports. Kept English so diagnostics stay greppable across locales
  (the trade Apple's own daemons make); a doc comment now records this. If
  a localized caption is ever wanted, derive it at display time — don't
  localize what gets persisted into the assertion.
- **`MacStat/Dropdown/SleepControlCard.swift:735,751`
  `SleepCountdownFormatting`** — `"4:09"` clock readouts and `"15 min"` /
  `"1 h"` unit forms. Numeric/unit formatting, pinned byte-for-byte by
  `SleepControlCardFormattingTests`; the right fix is
  `Date.ComponentsFormatStyle`/`Duration.formatted()`, a behavior change
  beyond a coverage pass.
- **`MacStat/Settings/Panes/AlertsPane.swift:1002,1036`
  `thresholdUnitLabel` ("GB"/"GB/s") and `hourLabel` ("%02d:00")** — unit
  symbols and a clock pattern, not prose.
- **`MacStat/Settings/Panes/AIAccessPane.swift:314`** — `risk ==
  "Medium"` compares a *kit-provided* English string
  (`MCPToolID.riskLabel`) to pick a tint, and `Text(risk)` displays it.
  Localizing the label in MacStatKit would silently break this comparison;
  the real fix is an enum-typed risk level on `MCPToolID`. Kit API change —
  out of scope here, flagged instead.
- **`MacStat/Dropdown/ModuleCards/BatteryHeroCard.swift:251` and
  `MacStat/Dashboard/BatteryOverviewCard.swift:157`** — `reason !=
  "Charging normally"` string-equality against kit-produced English
  (`notChargingReasonText`). Same disease as above: needs a structured
  "no reason" signal from the kit, not a translation.
- **`MacStatKit/Services/AlertEngine.swift:675–834` default rule names and
  notification copy** — kit-level (outside the audited directories),
  persisted into `settings.json` as user data on first run, and shared
  with non-UI consumers. Localizing defaults at creation is the likely
  right move (the pane's *new-rule* copy now does exactly that) but it
  belongs to a MacStatKit pass with a look at what happens to
  already-persisted English rule names.
- **`MacStat/App/MCPXPCService.swift:275–276, 394–398`** — MCP payload
  fields (`"Unknown Mac"`, capacity reasoning sentences) are machine
  output consumed by AI agents, excluded by the audit's charter. (The
  NSAlert and denial messages in the same file were already localized.)
- **`MacStat/Debug/*`, `MacStat/Debug/DebugWindowController.swift:58`** —
  debug surfaces, excluded by charter.
- **`MacStat/MenuBar/StatusItemView.swift:393`** — `"Sentry: " +
  parts.joined(", ")` — brand name plus a data list; the parts are
  formatted metric values, not prose.
- **`MacStatMobile/History/HistoryRangeSelector.swift:45–49`** —
  `"24h"/"7d"/"30d"/"90d"/"6mo"` compact range tokens. Unit-style
  abbreviations; the Mac catalog already carries them as manual keys, and
  a proper treatment (locale-aware unit abbreviation) is formatting work,
  not coverage.
- **`MacStatWatch/ContentView.swift:348–372` `WatchFormatting`** —
  `"38%"`, `"3h 40m"` numeric/unit output; `Duration.formatted()`
  territory.
- **`MacStatMobile/Intents/MacStatIntents.swift:252` /
  `MacStatWatch/Intents/MacStatWatchIntents.swift:269`** — the battery
  sentence still *appends* its optional trailing clauses (health, sleep,
  freshness) after the localized base sentence. Each clause is a whole
  localized phrase, but clause *order* is fixed by composition. Accepted:
  the alternative is one key per state combination (12+ near-duplicate
  sentences), a worse translator experience than an ordered enumeration of
  facts.
- **`MacStat/Dropdown/SystemVitals.swift` status reasons (`"\(title):
  \(note)"`)** — label-colon-value composition of two already-localized
  pieces; a "%1$@: %2$@" key would add nothing a translator can use.
- **Numeric `String(format:)` sites** — `GeneralPane.swift:282–290`
  (`"%.1f s"`), `ThemeEditorView.swift` (`"%.1f pt"`),
  `ModuleCardStack.swift:87` (`"%.0f°C"`), `EnergyReportCard.swift:101`
  (`"≈ %.1f kWh"`), `LocationPane.swift:100` (coordinates),
  `AlertsPane.swift` (`"%g"`, trimmed decimals). Numbers with SI unit
  symbols; `MeasurementFormatter` adoption is the real fix and a behavior
  change.
- **Interpolated `LocalizedStringKey` literals in the new-catalog targets**
  (e.g. `MacStatWidget/Views/SmallWidgetView.swift:30` `Text("\(…)W")`) —
  numeric readouts whose extracted keys are specifier-only (`"%lldW"`).
  Left for the first Xcode build to extract with exact specifiers rather
  than risk hand-seeding them wrong.
- **Preview/demo fixture strings** — `MacStatWatch/WatchSessionController
  .swift:78,99`, `MacStatWidget/Provider.swift:86`,
  `MacStatWatchWidget/Provider.swift:64` ("Malek's MacBook Pro", "Mac
  mini") — fixture data and proper nouns, not UI copy.

## Resulting key counts

| Catalog | Before | After |
|---|---|---|
| `MacStat/Resources/Localizable.xcstrings` | 183 | 547 |
| `MacStatKit/Resources/Localizable.xcstrings` | 120 | 120 (untouched) |
| `MacStatMobile/Resources/Localizable.xcstrings` | 48 | 123 |
| `MacStatWatch/Resources/Localizable.xcstrings` | — (didn't exist) | 80 |
| `MacStatWidget/Resources/Localizable.xcstrings` | — (didn't exist) | 18 |
| `MacStatWatchWidget/Resources/Localizable.xcstrings` | — (didn't exist) | 6 |
| **Total** | **351** | **894** |

All keys are English-source only; no `"localizations"` entry carries any
language other than `en`. Adding a language remains a deliberate,
reviewable decision — the point of this pass is that when that decision is
made, the strings will actually be there to translate.
