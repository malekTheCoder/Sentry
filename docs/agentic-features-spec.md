# Agentic features — specification and recommendation

Date: 2026-08-07 · Branch: `research/agentic-features` · Status: spec, nothing implemented

Sentry's MCP surface is decision-support for a machine, not a second dashboard
rendered as JSON. Every candidate below is judged against one question: **does
an agent need this to make a better decision than it can make today, or is it
a number a human would enjoy?** Three of the five candidates pass. One passes
only after being cut in half. One does not pass at all.

The existing surface this builds on: 20 tools in
`SentryKit/Services/MCPTool.swift`, described for a model reader in
`SentryKit/MCP/MCPToolCatalog.swift`, all funnelled through the single
enforcement point `Sentry/App/MCPXPCService.swift` (`authorize` →
`MCPAccessController.evaluate` → `AgentGuardrails.evaluate` → confirmation →
`MCPActivityLog` + `AgentSessionRegistry` + durable
`HistoryStore.logAgentActivity`).

---

## Ranked recommendation

### Build now

| # | Feature | One-line reason |
|---|---|---|
| 1 | **`notify_user`** (Mac-only in v1) | The only thing on this list an agent literally cannot do by any other means, and the gap it fills — "my 40-minute build finished and nobody knows" — is the single most-requested thing in the whole coding-agent ecosystem. |
| 2 | **Claude Code plugin: a `Stop` hook and a model-facing skill** | The repo ships 20 carefully prompt-engineered tool descriptions and *zero* instructions telling a model when to reach for them. Without this, `notify_user` is technically reachable and practically unused. Half a day. |
| 3 | **`diagnose_failure(since:)`** | Converts `get_resource_events_since`'s raw peaks into a ranked verdict with stable codes an agent can branch on — the reasoning Sentry can do from data the agent cannot see, in the `AgentPreflight.Assessment` shape agents already handle. |
| 4 | **Energy in `get_session_resource_report`** | Not a feature — a missing field. `EnergyIntegrator` is written and unit-tested, the watts series is persisted, the payload struct is additive by design. ~2 hours. Ship it as `notify_user`'s payload, not on its own. |

### Build later

| # | Feature | One-line reason |
|---|---|---|
| 5 | **Thermal ceiling guardrail** (the salvageable half of "resource budgets") | A user-set °C ceiling is a small numeric generalisation of the `thermalAutoRevokeEnabled` guardrail that already exists and already enforces; it needs `AgentPreflight` taught the same number so the two engines can't disagree. Half a day, but it must land *after* `notify_user` so a mid-build revocation is visible. |
| 6 | **Work spans (`begin_work` / `end_work`)** — my own proposal | The best of the extras: fixes agents leaking indefinite keep-awake holds, makes session reports scoped to a real job instead of a guessed `sinceSeconds`, and gives `get_agent_capacity` "8 minutes into a 40-minute build" instead of "someone called a tool recently." |
| 7 | **Notification relay to iPhone / Watch** | Genuinely valuable, but it is new transport work, not a feature toggle — see §1.2 and §1.10. Deferring it is why `notify_user` v1 must not *promise* it. |

### Don't build

| # | Feature | One-line reason |
|---|---|---|
| 8 | **Energy/Wh-per-day budget** (the other half of "resource budgets") | Energy is machine-wide and unattributable, and does not exist at all on desktop Macs — a budget that punishes an agent for Final Cut's power draw, and that silently never fires on a Mac Studio, is guardrail theatre. |
| 9 | **Multi-Mac awareness** | Fails the decision test twice over: an agent on Mac A cannot *do* anything with Mac B, and there is no Mac-to-Mac transport, no peer discovery, and no stable `deviceID` to build one on. §4 lists the prerequisites so this can be reconsidered honestly later. |

**Single strongest recommendation: `notify_user`, shipped in the same change
as the Claude Code `Stop` hook and skill that make it reachable.** The tool
without the integration is a capability nobody invokes; the integration
without the tool is a shell script calling `osascript`, which is what
`integrations/claude-code/settings.example.json` already does.

---

## 1. `notify_user` — build now

### 1.1 The problem

An agent that has been building for forty minutes finishes, and has no way to
say so. Its only output channel is the terminal transcript the human stopped
watching thirty-nine minutes ago. Every other tool on Sentry's surface is the
agent *asking the Mac* something; this is the one case where the agent needs
the Mac to *speak on its behalf*.

The workaround is already in this repo, and it is embarrassing:
`integrations/claude-code/settings.example.json` binds a `Stop` hook to

```sh
/bin/sh -c 'SUMMARY=$(sentryctl session-report --since=1800); osascript -e "display notification \"$SUMMARY\" ..."'
```

— a shell escape hatch that shells out to AppleScript to do something Sentry
is already better positioned to do, with no rate limiting, no Do-Not-Disturb
awareness, no quiet-hours awareness, no attribution, and a shell-quoting hole
in the middle of it. `integrations/claude-code/plugin/README.md` even names
the third-party tools (`claudecodenotify`, `claude-notify`) that exist purely
because this gap exists.

Sentry already owns the delivery path, the mute settings, the quiet-hours
policy, the per-client identity, and the audit log. This is the most
"agentic" feature available and it is mostly wiring.

### 1.2 Honest scoping: Mac only, in v1

The brief describes "a live relay to the paired iPhone and Apple Watch." That
relay carries *metrics*, not messages. Concretely:

- `LocalSyncFraming.LocalSyncMessage`
  (`SentryKit/LocalSync/LocalSyncFraming.swift`) has exactly three cases —
  `.snapshot`, `.command`, `.status`. There is no notice/message kind.
- `AlertAction.pushToPhone` was **cut on Aug 13, 2026** along with the
  queue it fed (`PendingAlertPushStore`, deleted) — delivery never
  shipped. The enum case survives only so rules persisted by earlier
  builds still decode; the engine treats it as a documented no-op, and
  `create_alert_rule` refuses rules that carry it.
- The iPhone app contains **zero** references to `UNUserNotificationCenter`,
  no `UIBackgroundModes`, no push entitlement, no NSE. It cannot raise a
  notification at all, and `SentryMobile/Data/AppDataSource.swift` documents
  that its `LocalSyncClient` connection is torn down whenever the app is
  backgrounded.
- `WatchRelaySnapshot` (`SentryKit/Watch/WatchRelaySnapshot.swift`) is a fixed
  set of metric fields with no free-text field, throttled by
  `WatchRelayPolicy.minimumRelayInterval = 5 * 60`.

So: **v1 delivers a macOS notification and nothing else, and the tool
description must not claim otherwise.** §1.10 sizes the relay as a later,
separate piece of work.

### 1.3 Read or write

**Write.** It has a user-perceptible side effect on a surface the user did not
ask for, which is exactly the bar `MCPToolID.isWrite` encodes. It therefore
ships **off by default** (`enabledByDefault == !isWrite`), gets a row in
Settings → AI Access, and passes through the guardrail engine.

`riskLabel`: **Medium** — above `keep_awake`'s "Low" because it can interrupt
the user, below nothing (it is the highest-risk tool that does not mutate
Sentry state).

It must **not** be added to `mcpConfirmationRequiredToolIDs` by default. A
native `NSAlert` asking "may this agent show you a notification?" is a
notification with extra steps; the confirmation mechanism is the wrong tool
here. The gating that matters is the per-tool toggle, the notification budget
(§1.6), Do-Not-Disturb, and quiet hours.

### 1.4 Tool name and schema

`MCPToolID` case, in `SentryKit/Services/MCPTool.swift`:

```swift
/// Lets an agent reach the human when the human is no longer watching the
/// terminal — the only outbound channel on this surface. See
/// `MCPToolCatalog.agentFacingDescription` for the budget discipline the
/// description asks of a calling model.
case notifyUser = "notify_user"
```

Schema, in `MCPToolCatalog.inputSchema(for:)`, matching the file's existing
`schema(properties:required:)` helper:

```swift
case .notifyUser:
    return schema(
        properties: [
            "title": property("string", "One short line, 60 characters or fewer — what happened. Rendered as the notification's title, prefixed with your client name so the user knows who is speaking."),
            "body": property("string", "One or two sentences, 200 characters or fewer — the outcome, and what (if anything) the user should do next. Never file contents, credentials, command output, or anything you would not put on a postcard."),
            "urgency": property("string", "One of: normal (default), time_sensitive. time_sensitive can break through a Focus mode and is only honored when the user has allowed agents to send it; otherwise it is silently downgraded to normal and the reply says so.")
        ],
        required: ["title", "body"]
    )
```

Annotations fall out of the existing derivation in `MCPToolCatalog.tools`:
`readOnlyHint: false`, `destructiveHint: false`, `idempotentHint: false`,
`openWorldHint: false`.

### 1.5 Agent-facing description

Written for a model reader, in `agentFacingDescription(for:)` — same voice as
the existing `preflightCheck` / `waitUntilReady` copy, which spends most of
its words telling the model what *not* to do:

```swift
case .notifyUser:
    return """
    Tell the human at this Mac something they need to know — a long build finished, a \
    test suite went red, you are blocked and waiting on a decision. This is the only way \
    you can reach the user when they are not watching your terminal; Sentry delivers it as \
    a macOS notification attributed to your client name. Call it ONCE, when work the user \
    is waiting on ends or genuinely stalls — never as a progress ticker, never per file, \
    never to acknowledge an instruction. The budget is small (a few per hour, per client) \
    and shared with nothing else: if you spend it narrating, the notification that actually \
    mattered will be refused. A refusal is final for that window — do not retry it, do not \
    reword it and try again, just say it in your text output instead. The user may have \
    muted agent notifications or set quiet hours, in which case this returns "not \
    delivered" and nothing was shown; that is a preference, not an error to work around. \
    Keep the body to one or two sentences of status: it renders on a lock screen, so it \
    must never contain file contents, credentials, command output, or anything private.
    """
```

Two things that copy is deliberately doing, both borrowed from the existing
descriptions: it gives the model a *budget model* rather than a prohibition
(the `preflight_check` description does the same with "tell the user instead
of retrying"), and it pre-empts the retry loop the way the `wait_until_ready`
description pre-empts polling.

### 1.6 Where it plugs in, and the rate-limit design

**XPC protocol** (`SentryKit/XPC/SentryXPCProtocol.swift`), write-tool reply
shape:

```swift
func notifyUser(clientName: String, title: String, body: String, urgency: String,
                reply: @escaping (Bool, String?) -> Void)
```

**Enforcement** (`Sentry/App/MCPXPCService.swift`) — identical to every other
write tool, with one existing mechanism reused deliberately:

```swift
nonisolated func notifyUser(clientName: String, title: String, body: String, urgency: String,
                            reply: @escaping (Bool, String?) -> Void) {
    Task { @MainActor in
        let summary = "title=\(title)"
        // Same split `createAlertRule` already uses: the confirmation dialog
        // and in-memory feed may show what was said, but the durable
        // `agent_activity_log` row must not persist a model-authored body
        // forever. `logAgentActivity`'s contract is a SHORT summary, never
        // raw arguments.
        guard let reply = self.authorizeInstrumented(
            .notifyUser,
            wireClientName: clientName,
            argumentsSummary: summary,
            persistedSummary: "notified the user (message not persisted)",
            reply: reply
        ) else { return }
        …
    }
}
```

So the whole existing chain applies for free: master switch → per-tool toggle
→ per-client rate limit → guardrails (kill switch, per-client revocation,
on-battery, quiet hours) → `MCPActivityLog` row → `AgentSessionRegistry`
presence → durable audit row with duration and outcome.

**The generic rate limit is not enough, and this is the part that needs
thought.** `AppSettings.mcpRateLimitPerMinute` defaults to 20 *per minute*.
Twenty banners a minute is not a notification feature, it is an attack. So
`notify_user` needs a second, much tighter budget, and three specific
properties:

1. **Its own window, not `MCPAccessController`'s.** A dedicated
   `AgentNotificationBudget` — same shape as `MCPAccessController`'s
   per-client array-of-timestamps plus `globalCeilingMultiplier`, because
   that pattern already survived exactly this threat model. Defaults:
   **3/hour per client, 6/hour Mac-wide.**
2. **Separate from `AlertEngine.rateCapPerHour`.** The user's alert budget
   (`notificationRateCapPerHour`, default 6) belongs to *the user's own alert
   rules*. An agent must not be able to exhaust it and thereby suppress the
   "battery critically low" notification the user actually configured. Two
   budgets, no shared pool.
3. **Refusal is honest and final.** Over budget returns
   `(false, "Sentry declined this: \(clientName) has used its notification \
   budget for this hour (3 of 3). It can send another after HH:MM.")` — the
   `AgentGuardrails` voice, verbatim to the agent, with a concrete time so the
   model can decide rather than retry.

**Delivery** reuses `AlertEngine.deliverGuardrailNotice(title:body:)`
(`SentryKit/Services/AlertEngine.swift:982`) — the existing precedent for a
non-rule, non-user-authored notification that shares the lazy
`requestAuthorizationIfNeeded()` path and honors `doNotDisturb`, without
writing to `alert_log` or consuming the alert rate cap. It needs a sibling,
because `deliverGuardrailNotice`'s rate-cap *exemption* is correct for
Sentry's own guardrail announcements and wrong for an agent:

```swift
/// Agent-originated notice (`notify_user`). Unlike `deliverGuardrailNotice`,
/// this is subject to a caller-supplied budget check *before* it reaches
/// here — see `AgentNotificationBudget` — and its thread identifier is
/// per-client so one agent's messages group together instead of interleaving
/// with another's.
public func deliverAgentNotice(title: String, body: String,
                               clientName: String, timeSensitive: Bool) -> Bool
```

Content rules enforced at the boundary, not trusted to the model:

- Title and body pass through the existing
  `MCPXPCService.sanitizedForDialog(_:maxLength:)` — newline-flattened,
  truncated (60 / 200). That function exists precisely because "`clientName`
  and the arguments summary are attacker-controlled for a hostile local
  process"; a notification is a strictly more public rendering surface than
  the dialog it was written for.
- Title is **prefixed with the sanitized client name**, so nothing an agent
  writes can render as if Sentry itself said it.
- `interruptionLevel` is `.active` unless the user has opted in to
  time-sensitive agent notices; agents never get `.critical`.
- `categoryIdentifier` stays unset, as it is today. No actions, no buttons,
  no tap handling — an agent-authored notification must not be able to
  present an actionable control.

### 1.7 User controls (new settings)

Added to `AgentGuardrailSettings`
(`SentryKit/Services/AgentGuardrails.swift`), following that struct's
established additive-`Codable` discipline (every key optional, every absence
falling back to the shipped default):

```swift
/// Master mute for `notify_user`. On by default *only because the tool
/// itself is off by default* — a user who has deliberately enabled
/// notify_user in AI Access has already made the decision this flag would
/// otherwise ask twice.
public var agentNotificationsEnabled: Bool = true
/// Per-client budget, per hour. See AgentNotificationBudget.
public var agentNotificationsPerHour: Int = 3
/// Whether quiet hours (already configured above for keep-awake) also
/// silence agent notifications. On by default: a user who told Sentry
/// agents may not hold this Mac awake at 02:00 has said something about
/// 02:00, not only about keep-awake.
public var agentNotificationsRespectQuietHours: Bool = true
/// Whether an agent may request time_sensitive urgency (Focus break-through).
/// Off by default — agents do not get to override a Focus mode until the
/// user says they may.
public var agentNotificationsMayBeTimeSensitive: Bool = false
```

Quiet-hours enforcement is one clause in the existing
`AgentGuardrails.evaluate`, next to the `keepAwake` clause it mirrors:

```swift
if settings.quietHoursEnabled,
   settings.agentNotificationsRespectQuietHours,
   tool == .notifyUser,
   isWithinQuietHours(...) {
    return .deny(reason: String(localized: "Sentry declined this: quiet hours (\(…)–\(…)) are in effect — agents may not notify you right now."))
}
```

Do-Not-Disturb (`AppSettings.doNotDisturb`) is inherited for free from the
`AlertEngine` delivery path. Per-client muting is already expressible via
`revokedClientNames` (which denies *everything* from that client) — a
notification-only mute is a nice-to-have, not a v1 requirement.

### 1.8 Reuses vs. new

**Reuses:** `AlertEngine`'s `UNUserNotificationCenter` wrapper and lazy
authorization; `doNotDisturb`; `AgentGuardrails`' quiet-hours window and
denial-sentence voice; `MCPXPCService.authorizeInstrumented` including the
`persistedSummary` override; `sanitizedForDialog`; `MCPActivityLog`'s
denied-entry partition (a notification flood recycles only its own audit
slots — see that type's doc comment); `AgentSessionRegistry`.

**New:** one `MCPToolID` case (which the compiler turns into a checklist
across `isWrite` / `riskLabel` / `displayName` / `toolDescription`); one
`SentryXPCServiceProtocol` method; one schema + description + dispatch arm;
`AlertEngine.deliverAgentNotice`; `AgentNotificationBudget` (~60 lines,
modelled on `MCPAccessController`'s window); four `AgentGuardrailSettings`
fields; one AI Access pane row; tests.

### 1.9 Claude Code integration — what makes it reachable

This is the half that actually determines whether the feature gets used, and
today the repo has none of it. `integrations/claude-code/plugin/hooks/hooks.json`
binds exactly one event:

```json
{ "hooks": { "PreToolUse": [ { "matcher": "Bash",
  "hooks": [ { "type": "command", "command": "sentryctl hook pretooluse" } ] } ] } }
```

There is no `Stop` hook in the plugin (only in the un-shipped
`settings.example.json`), no `skills/`, no `commands/`, and **no `CLAUDE.md`
anywhere in the repository**. The only model-facing prompt text in the entire
project is `MCPToolCatalog.agentFacingDescription`. A model is never told
that `preflight_check` exists before a long build, let alone `notify_user`
after one.

Minimum to make `notify_user` real in practice:

1. **A `Stop` hook in the plugin**, replacing the `osascript` example, that
   posts the finish notification with the session's actual cost:
   `sentryctl notify --from-session --since=1800`. This is the highest-value
   line of the whole feature — it means a user who installs the plugin gets
   end-of-run notifications with *no model cooperation required at all*.
   Deterministic beats prompted.
2. **A `SubagentStop` hook: no.** Deliberately. One Claude Code session maps
   to one `SentryMCP` process and one `MCPClientIdentity.sessionID` — every
   subagent shares it (documented at length in
   `integrations/claude-code/scripts/subagent-statusline.sh`). A per-subagent
   notification would fire N times per run against a 3/hour budget.
3. **A skill** (`plugin/skills/sentry-mac/SKILL.md`) that tells the model the
   three-line policy: preflight before sustained work, keep-awake for the
   duration, notify once at the end or when blocked. This is the layer that
   makes the *model-initiated* "I am blocked, please decide" case work — the
   `Stop` hook can only cover "it ended."
4. **A `sentryctl notify` subcommand** so the hook has something to call.
   `SentryCLI/main.swift`'s dispatch switch gains one arm; the XPC method
   already exists by then.

Note the prerequisites that already gate everything in `integrations/`:
`sentryctl` must be symlinked onto `$PATH` and the user must have run
Settings → AI Access → Set Up Command-Line Access once. And on a build not
signed with a Developer ID certificate, `SMAppService` registration cannot
succeed and every hook fails — that is a pre-existing distribution problem,
not one this feature introduces, but it caps how much the hook can be relied
on.

### 1.10 Effort

- Tool + delivery + budget + settings + pane row + tests: **1.5–2 days.**
- `sentryctl notify` + `Stop` hook + skill markdown: **0.5 day.**
- Phone/Watch relay (deferred): a new `LocalSyncMessage` kind (which is
  additive for matched builds but **connection-fatal against an older peer** —
  `LocalSyncFraming` has no version byte and both sides treat
  `FramingError.unknownKind` as fatal with no resync), plus the first
  `UNUserNotificationCenter` usage in `SentryMobile`, plus an honest answer
  to "the phone is only connected while foregrounded." **~1 week and a
  protocol decision.** Do not bundle it.

---

## 2. Resource budgets — build half of it, later

### 2.1 What already enforces

The brief frames guardrails as "a kill switch plus per-client rate limits."
That undersells what is there. `AgentGuardrails` already enforces four
conditional policies at two moments — the gate
(`AgentGuardrails.evaluate`, run inside `MCPXPCService.authorize` before any
tool executes) and the revoker (`AgentGuardrails.autoRevocationReason`, run
per snapshot tick by `AppDelegate.enforceAgentGuardrailRevocation` against a
live agent-held assertion):

| Policy | Denies | Revokes mid-hold | Default |
|---|---|---|---|
| Kill switch | everything | yes | off |
| Per-client revocation | everything from that name | yes (via settings sink) | — |
| On-battery restriction | all write tools | no | off |
| Battery floor | `keep_awake` (optionally all writes) | no | **on**, 20% |
| Quiet hours | `keep_awake` | yes | off |
| Thermal auto-revoke | `keep_awake` at pressure ≥ serious | yes | **on** |
| External `caffeinate` arbitration | — | terminates the process | **on** |

So "what does enforcement actually do" is already answered by the codebase:
it refuses the call with a complete honest sentence the agent reads verbatim,
and it releases an existing hold and announces it
(`AppDelegate.announceAgentRevocation` → notification + `MCPActivityLog` row).
A budget does not need new enforcement machinery. It needs a new *predicate*.

### 2.2 The thermal ceiling — worth building

`thermalAutoRevokeEnabled` fires on macOS's coarse `ThermalStats.PressureLevel`
(`serious` / `critical`). A user who wants "agents may not push this Mac past
90 °C" wants the same enforcement keyed on `socTemperatureCelsius`, which is
already collected and already persisted as `thermal.soc_temp_c`.

```swift
// AgentGuardrailSettings
/// Hard SoC-temperature ceiling for agent-held keep-awake. Off by default:
/// a °C number is a preference (and a machine-specific one — an M1 Pro's
/// nominal sustained load temperature is not an M4 Max's), unlike the
/// pressure-level policy above, which uses macOS's own judgment.
public var thermalCeilingEnabled: Bool = false
public var thermalCeilingCelsius: Double = 95
```

Three edits, all in places that already exist:

1. `AgentGuardrails.PowerContext` gains `socTemperatureCelsius: Double?`,
   populated in the single `PowerContext.from(snapshot:)` construction path
   that already reads `snapshot.thermal`. The `nil`-never-denies convention
   documented on that struct carries over unchanged.
2. `evaluate` gains one clause after the existing thermal clause; the
   `autoRevocationReason` mirror gains one too.
3. **`AgentPreflight` must be taught the same number.** This is the part that
   is easy to get wrong. `preflight_check` and `keep_awake` must never
   disagree — the codebase already treats that as a correctness property
   (`wait_until_ready`'s description promises it "returns exactly when
   preflight_check would stop saying wait, so the two can never disagree").
   A ceiling that denies `keep_awake` while `preflight_check` says `proceed`
   is a bug, not a policy. So: a new
   `AgentPreflight.ReasonCode.userThermalCeiling = "user_thermal_ceiling"`
   with severity `.wait` (waiting genuinely does fix it, unlike
   `thermal_critical`), and `assess(...)` gains an optional ceiling
   parameter passed from `MCPXPCService.preflightCheck`.

**Effort: half a day.** But sequence it *after* `notify_user`: a ceiling that
revokes a hold in the middle of a build the user is waiting on, and announces
it only in a menu-bar activity feed nobody is looking at, is a bad surprise.
`deliverGuardrailNotice` already fires on revocation, so this is mostly
already true — but the whole point of the ordering is that the user should by
then be used to Sentry speaking about agent activity.

### 2.3 The energy budget — don't build

"Agents may not push this Mac past 200 Wh/day" fails on three independent
grounds, any one of which is disqualifying.

**It is not attributable.** Sentry measures the machine, not the agent. The
existing `MCPPayloads.SessionResourceReport.batteryPercentDrained` carries
this caveat in its own doc comment — "'during this session,' not 'caused by
it': every other process on the Mac drained the same battery." A budget that
*denies* an agent's `keep_awake` because the user spent the afternoon in Final
Cut is enforcement pointed at the wrong party, and — worse — it is
enforcement the user will experience as random, because the input is
invisible to them.

**It does not exist on the machines that matter most.** The only whole-system
power series is `battery.system_power_watts`, read from `AppleSmartBattery`'s
`PowerTelemetryData` in `SystemMetricsKit/Collectors/BatteryCollector.swift`.
`BatteryCollector.collect()` returns `nil` on a Mac with no internal battery.
A Mac Studio or Mac mini — precisely the always-plugged-in desktop most likely
to be an agent workhorse — produces no energy data at all, so the budget would
silently never fire there. A guardrail whose enforcement depends on chassis
type is one users cannot reason about. (`cpu.power_watts` is not a fallback:
`MetricID.cpuPowerWatts` is wired end-to-end through `HistoryStore` but
`CPUCollector` never sets `packagePowerWatts` — it is a dead metric.)

**The thing it is actually trying to prevent is already prevented.** The
failure modes a user fears — a laptop cooked overnight, a battery drained to
nothing while unplugged, a machine held awake through the small hours — are
covered by thermal auto-revoke, the battery floor, and quiet hours
respectively, each keyed on a signal that is *directly* observable and
*directly* about the harm. Wh/day is a proxy for all three and worse than each.

Report energy (§5). Do not enforce on it.

---

## 3. `diagnose_failure(since:)` — build now

### 3.1 The problem

`get_resource_events_since` hands an agent five numbers —
`peakSoCTemperatureCelsius`, `peakCPUPercent`, `peakMemoryPressurePercent`,
`minDiskFreeBytes`, `anyThrottling` — and a list of alert firings, and leaves
the model to work out what they mean. That is the wrong division of labour in
both directions: the model burns tokens re-deriving thresholds it does not
know, and Sentry declines to apply reasoning it has already written
(`SentryKit/Insights/` is ~57 rules that do exactly this kind of
evidence-to-finding inference over the same history store).

Worse, the raw numbers cannot answer the most valuable question. "Did the
machine sleep?" is invisible in a peak-value summary — it shows up as a *gap*
in the sample series, and detecting that gap correctly requires knowing the
expected cadence, which the agent has no way to learn.

### 3.2 What can and cannot be answered — state this up front

| Candidate cause | Answerable? | From what |
|---|---|---|
| Thermal throttling | **Yes, well** | `thermal.is_throttling` + `thermal.pressure_level`, persisted at raw fidelity inside 48 h; `AgentSessionReport.thermalElevation(samples:windowStart:)` already turns them into a duration |
| Machine slept | **Yes, inferred** | A gap in `sample_raw`. `SentryKit/History/ChartScrubbing.swift` already has exactly this: `gaps(timestamps:threshold:)`, `gapThreshold(cadence:)`, `effectiveCadence(...)`, and a doc comment naming the exact distinction — "still 0%, still being measured" vs "Mac asleep, nothing measured at all" |
| Disk filled | **Yes** | `disk.free_bytes` minimum in window |
| Another agent contending | **Yes** | `AgentSessionRegistry` + `agent_activity_log` |
| Memory exhaustion / OOM kill | **Partially, and it must say so** | There is no jetsam source, no page-out metric, and `memory.pressure_percent` is **never written** by `HistoryStore.metricPairs`. The honest evidence is `memory.used_bytes` against installed RAM, `memory.swap_used_bytes` growth, and `memory.compressed_bytes` — exactly what `InsightHistorySummaries.MemoryHistorySummary` computes, under its own wording rule: "memory in use," never "memory pressure was critical" |
| Why it slept / what killed the process | **No** | No pmset log reading, no `kern.memorystatus` event feed, no process-exit log. `NSWorkspace.didTerminateApplicationNotification` is observed in one place and cannot see a `swift build` anyway |

**Bug found while specifying this.** `MCPXPCService.getResourceEventsSince`
queries `MetricID.memoryPressurePercent`, which no collector ever persists —
so `ResourceEventsSummary.peakMemoryPressurePercent` is **always `nil`** in
production today. Either start persisting `memory.pressure_percent` (the
collector reads it live already, via
`sysctl kern.memorystatus_vm_pressure_level` in
`SystemMetricsKit/Collectors/MemoryCollector.swift`) or delete the field. This
should be fixed *before* `diagnose_failure` ships, because the memory branch
of the diagnosis is materially better with a real pressure series than with
the used-bytes proxy.

### 3.3 Read or write

**Read.** No side effects, nothing to confirm, ships enabled by default like
its sibling `get_resource_events_since`. Passes the kill switch and per-client
revocation (which read tools do), and nothing else — correct, since the
conditional guardrails are write-tool concerns by construction.

### 3.4 Schema

```swift
case .diagnoseFailure:
    return schema(
        properties: [
            "sinceSeconds": property("number", "How far back, in seconds, the run that failed started. Use the job's real start time, not a round number — a window much wider than the run dilutes the evidence and a narrower one can miss the cause."),
            "symptom": property("string", "Optional hint about how the job died, used to rank competing evidence: one of killed, hung, slow, disappeared, unknown (default).")
        ],
        required: ["sinceSeconds"]
    )
```

### 3.5 Agent-facing description

```swift
case .diagnoseFailure:
    return """
    Ask this Mac what happened to a run that just failed. Give sinceSeconds spanning the \
    failed job and get back ranked candidate causes — each with a stable code you can branch \
    on (thermal_throttling, machine_slept, memory_exhaustion, disk_full, agent_contention, \
    power_loss, nothing_anomalous), a confidence, a human sentence, and the measured numbers \
    the finding was drawn from. Prefer this over get_resource_events_since when you want the \
    reasoning done for you; that tool still exists for when you want the raw peaks and will \
    do your own analysis. Read the verdict honestly: Sentry watches the machine, not your \
    process, so every finding means "this happened on this Mac during your window," never \
    "this killed your build" — confidence says how far the evidence narrows it, and \
    nothing_anomalous is a real, useful answer meaning the machine was fine and the fault is \
    in your own logs. Two causes can never be fully confirmed from here and say so in their \
    own text: an out-of-memory kill (this Mac records memory in use and swap growth, never \
    the kill itself) and why the machine slept (inferred from a gap in sampling, which a \
    crashed Sentry would also produce).
    """
```

### 3.6 Result payload

New struct in `SentryKit/XPC/MCPPayloads.swift`, appended after
`AgentCapacityReport` (the file's own convention: "appended, never
reordered"), and shaped deliberately like `AgentPreflight.Assessment` so an
agent that already handles one handles the other:

```swift
public struct DiagnosisReport: Codable, Sendable {
    public let windowStart: Date
    public let windowEnd: Date
    /// Most likely first. Empty means the same as a single
    /// `nothing_anomalous` finding and is never returned — an empty list
    /// would read as "we found nothing to say," which is a different claim.
    public let findings: [DiagnosisFinding]
    /// What this window could not have answered regardless of what happened —
    /// e.g. "raw samples only reach back 48h; this window starts before that,
    /// so evidence before <date> is hourly averages." Present so the agent
    /// can distinguish "ruled out" from "not observable."
    public let limitations: [String]
    public let sampleCoverage: SampleCoverage
}

public struct DiagnosisFinding: Codable, Sendable {
    public let code: String        // stable snake_case, never renamed
    public let confidence: Double  // 0…1
    public let message: String     // one honest sentence, quoting a number
    public let evidence: [String]  // the measured values behind it
    public let firstObservedAt: Date?
    public let lastObservedAt: Date?
}
```

(The `firstObservedAt` / `lastObservedAt` pair is what lets an agent correlate
against its own log timestamps — "throttling started at 14:01:40, my build
died at 14:02:07" is a far stronger inference than "throttling happened
sometime in this window," and it is the single field most likely to change the
agent's next action.)

### 3.7 Reuses vs. new

**Reuses:** `ChartScrubbing.gaps` / `effectiveCadence` (sleep detection —
already written and tested, and its doc comment describes this exact use
case); `AgentSessionReport.thermalElevation`; `InsightAggregates`
(`secondsAtOrAbove`, `longestRunSecondsAtOrAbove`, `coincidence(trigger:…)`,
`maximumGap = 300`); `InsightHistorySummaries.MemoryHistorySummary` /
`ThermalHistorySummary` / `StorageHistorySummary`; `InsightPhrasing` for the
number formatting; `HistoryStore.samples(metric:since:)`' auto-tier selection
(a same-day window lands on `.raw`).

**New:** a pure `FailureDiagnosis` engine in `SentryKit/Services/`, in
`AgentPreflight`'s style — a caseless enum of static functions, taking
already-fetched sample series and returning findings, with no store reference
so it is exhaustively unit-testable on fabricated history. Roughly 6–8 rules.

On reusing `ProtectionInsightsEngine` directly: **don't.** Its `evaluate` loop
is genuinely generic (`rules × context × suppressions → insights`), but
`ProtectionInsightsReport.score` is a non-optional `ProtectionScore` computed
from an exhaustive switch over the eight `InsightCategory` cases, and
`InsightContextBuilder.build` does 15 history queries over a 30-day window.
Neither is appropriate for a 20-minute post-mortem. Copy the *pattern* — pure
rule, evidence required, `nil` rather than a hedge — and reuse the aggregate
and summary helpers, which are the actually valuable part.

### 3.8 Claude Code integration

None required — a read tool an agent calls when its own build fails is
reachable the moment it exists. Worth one line in the skill from §1.9 ("when a
long-running command fails unexpectedly, call `diagnose_failure` with the
elapsed time before assuming it was your code"), because that is the moment a
model is least likely to think of asking the machine.

### 3.9 Effort

**2–3 days**, plus half a day for the `memory.pressure_percent` persistence
fix that should precede it.

---

## 4. Multi-Mac awareness — don't build

### 4.1 It fails the decision test

"Which of my Macs is coolest and idlest right now?" is a question an agent can
*ask* and cannot *act on*. The agent runs on one Mac. It has no mechanism to
move its work to another one — no remote execution, no job dispatch, no shared
filesystem contract. The answer changes nothing it does next. That makes it a
stat a human would like, rendered as JSON, which is the exact anti-pattern
this surface is supposed to avoid.

The version that *would* pass the test — "start this build on the cool Mac" —
is a distributed job runner. That is not an adjacent feature to a system
monitor; it is a different product.

### 4.2 The transport does not exist either

Even setting the value question aside, the honest engineering position:

- **No macOS process in this repo ever browses Bonjour.** `NWBrowser` appears
  in exactly one non-test file, `SentryKit/LocalSync/LocalSyncClient.swift`,
  and the only two constructions are in `SentryMobile` and inside an
  `#if os(iOS)` guard in `SentryWidget`. The Mac is server-only
  (`LocalSyncServer` is `#if os(macOS)`).
- **The phone talks to one Mac at a time.** `LocalSyncClient` holds a single
  `private var connection: NWConnection?`; `switchTo(discovered:)` cancels
  before it dials. The picker in
  `SentryMobile/Settings/SettingsTabView.swift` (`macPickerSection`) is a live
  browse list, not a fleet view.
- **`deviceID` is not stable.** `StatsCoordinator.deviceID` defaults to
  `UUID().uuidString` and is never persisted — its own doc comment carries the
  TODO. Every Mac gets a new identity on every launch. Any fleet concept is
  keyed on something that changes hourly.
- **CloudKit is blocked, not stubbed-and-ready.** `SentryKit/Sync/` is
  complete-looking scaffolding with zero `CKContainer` constructions anywhere
  in the tree and no iCloud entitlement in `project.yml`, blocked on Apple
  Developer Program enrolment that `Sentry/Settings/Panes/SyncPane.swift`
  states plainly: `SyncService` "is constructed nowhere in `AppDelegate` and
  has no `uploadAttempt` closure that talks to a server, because there is no
  server to talk to."

### 4.3 If it is ever reconsidered, this is the honest path

Not an MCP tool. The realistic build is **`sentryctl --host=<peer>`** over the
existing TLS-PSK remote path (`LocalSyncServer.enableRemote(port:pairingCode:)`),
which already authenticates and already gates command issuance on
`isAuthenticated`. `LocalSyncClient` compiles into `SentryKit_macOS` today and
has `configureDirectEndpoint(host:port:pairingCode:)`, so the transport would
work unmodified.

Prerequisites, in order: (1) persist `deviceID`; (2) a persisted peer list on
macOS; (3) a multi-connection model, since `LocalSyncClient` is
single-connection by construction; (4) a human answer to "what does the agent
do with the answer." Until (4) has one, the first three are wasted work.

---

## 5. Run cost attribution — mostly already built, finish it

### 5.1 Where it stands

`get_session_resource_report` already returns, per the caller's own session:
`averageCPUPercent`, `peakCPUPercent`, `peakSoCTemperatureCelsius`,
`secondsThrottling`, `alertsFired`, `toolCallCounts`, `keepAwakeSecondsHeld`,
`batteryPercentDrained`, `thermalPressureElevated`,
`thermalPressureElevatedSeconds`. "That run cost 6 minutes of throttling" is
**shipped**.

"That run cost 42 Wh" is the only missing half, and the hard part of it is
done: `SentryKit/History/EnergyIntegrator.swift` —
`kilowattHours(samples:maximumGap:)`, left-Riemann with a 300 s per-gap cap so
a sleeping Mac does not accrue phantom energy — exists, is unit-tested
(`SentryTests/EnergyIntegratorTests.swift`, including the sleep-gap case), and
runs in production behind `Sentry/Dashboard/EnergyReportCard.swift`. The
`battery.system_power_watts` series it needs is persisted.

### 5.2 The change

In `MCPXPCService.getSessionResourceReport`, one more history query beside the
four already there, and one call:

```swift
let powerSamples = self.historyStore
    .samples(metric: MetricID.batterySystemPowerWatts.rawValue, since: since)
    .map { (timestamp: $0.timestamp, watts: $0.value) }
let wattHours = powerSamples.isEmpty
    ? nil
    : EnergyIntegrator.kilowattHours(samples: powerSamples) * 1000
```

Plus one additive optional field on `MCPPayloads.SessionResourceReport`
(`wattHoursConsumed: Double?`) — the sanctioned shape, per that struct's own
"appended, never reordered" header — and one line in
`SentryCLI/main.swift`'s `runSessionReport`.

### 5.3 Two caveats that must ship with it, not be discovered later

1. **Machine-wide, not agent-attributable** — the same caveat
   `batteryPercentDrained` already documents. The field's doc comment and the
   tool description must say "energy this Mac drew during your window,"
   never "energy your run cost."
2. **`nil` on desktop Macs.** `BatteryCollector.collect()` returns `nil`
   without an internal battery, so there is no `system_power_watts` series on
   a Mac mini / Studio / Pro. Optional field, and the description must say
   why it can be absent — otherwise a model on a Mac Studio will interpret
   `nil` as "zero energy" or as a bug.

### 5.4 Verdict

Strictly, this fails the decision test: knowing a finished run cost 42 Wh does
not change what the agent does next. Build it anyway, for two reasons — it is
~2 hours of work on machinery that already exists, and it is the *content* of
`notify_user`'s end-of-run message. "Build finished — 42 Wh, 6 minutes
throttling" is a notification worth reading; "Build finished" is not. Ship
them together; do not ship this alone.

---

## 6. Extra proposal: work spans (`begin_work` / `end_work`) — build later

The strongest thing I found that was not on the list.

**The problem.** Sentry knows an agent *called a tool*. It does not know what
work that call was for, when the work started, when it ended, or whether it
succeeded. Four consequences, all real today:

- `keep_awake` accepts an indefinite duration (capped at 24 h) and depends on
  the agent remembering to call `release_awake`. An agent that crashes, is
  interrupted, or simply forgets leaves the Mac awake for a day. There is no
  span to expire against.
- `get_session_resource_report(sinceSeconds:)` forces the caller to *guess*
  its own window. An agent that guesses 1800 when the build took 2400 reports
  the wrong cost, confidently.
- `get_agent_capacity` can only report "another session called a tool 40
  seconds ago." It cannot report "another agent is 8 minutes into work it
  expects to take 40" — which is the fact that would actually let a
  well-behaved agent decide to wait.
- `diagnose_failure` has to be told the window by the very agent whose run
  just failed.

**The shape.** Two write tools, or — better, and my recommendation — optional
parameters on tools that already exist:

- `keep_awake` gains `label: String` and `expectedDurationSeconds: Number`.
  The label is already half-there (`reason` is shown in Sentry's UI); the
  expected duration is what turns a hold into a span with a deadline.
- `release_awake` returns the span's report instead of bare `OK` — the
  `SessionResourceReport` for exactly the window it covered, energy included.
  This is the closed loop: no guessed `sinceSeconds`, no second call.

That removes two of the four problems for roughly a day of work and no new
tools. Standalone `begin_work` / `end_work` for agents that do not want a
sleep assertion would be a second day. `AgentSessionRegistry.Session` gains a
`currentSpan` field; `MCPPayloads.AgentSessionInfo` gains the label and
elapsed/expected so `get_agent_capacity`'s judgment sentence can use it.

**Why later, not now.** It is genuinely valuable but it is an ergonomics and
coordination improvement, not a missing capability — everything it enables can
be approximated today with a guessed window. `notify_user` cannot be
approximated by anything except a shell script.

---

## 7. What could go wrong

The codebase's existing doc comments are unusually honest about their own
limits; this section keeps that posture. Each item names the mitigation *and*
what remains unmitigated.

### 7.1 An agent that spams

**Scenario.** A model decides `notify_user` is how it reports progress and
sends one per file compiled. Or a buggy retry loop re-sends after every
refusal.

**Mitigated by:** a dedicated hourly budget (3/client, 6/Mac-wide) that is far
tighter than `mcpRateLimitPerMinute`'s 20/min and separate from the user's own
`AlertEngine.rateCapPerHour`, so an agent cannot starve the user's configured
alerts. Refusals are honest sentences with a concrete resume time, and the
description explicitly tells the model that a refusal is final for the window
and must not be reworded and retried. Thread-identifier grouping per client
means a burst collapses into one notification-centre stack rather than N
banners. And `MCPActivityLog`'s denied-entry partition already ensures a
denial flood recycles only its own audit slots, so the record of what actually
*was* delivered survives the flood — that mechanism was built for exactly this
threat and carries over free.

**Unmitigated:** the first three notifications of a spam run still land. A cap
is a cap; there is no way to know the fourth one was the important one. The
mitigation for *that* is the `Stop` hook (§1.9), which needs no model
cooperation at all and is therefore the reliable channel; `notify_user` is the
discretionary one.

### 7.2 An agent that lies about its identity

**Scenario.** A hostile local process presents `clientInfo.name` as "Claude
Code" and burns Claude Code's notification budget, or rotates names to evade a
per-client budget or a `revokedClientNames` entry.

**Mitigated by:** the Mac-wide ceiling, which is the existing answer to this
exact attack — `MCPAccessController.globalCeilingMultiplier`'s doc comment
already reasons through it ("a hostile process can dodge its own per-client
budget by rotating names, which is exactly what `globalCeilingMultiplier`
exists to bound"). The notification budget must copy that two-tier shape, not
just the per-client half. The kill switch remains the hole-free control: it
denies every call regardless of what the caller calls itself.

**Unmitigated, and it must stay documented:** `clientName` is self-reported.
Any process that can resolve `dev.malekswilam.sentry.xpc` can claim any name;
the app ships unsandboxed with `CODE_SIGNING_REQUIRED: NO`, so there is no
code-signing-based connection validation to add. Every surface that shows a
client name already says so (`AgentSessionRegistry`, `AgentGuardrailSettings`,
`AgentCapacityReport.sessionIdentityNote`), and a notification attributed to a
client name inherits that caveat — the notification prefix is a *label*, not
an attestation. The AI Access pane copy should not be allowed to drift into
implying otherwise.

### 7.3 A tool that leaks something private

**`notify_user` is the highest-risk surface on this list**, and the risk is
structural: the body is free text authored by a model that has spent the last
forty minutes reading the user's source code, and a notification renders **on a
lock screen** — visible to anyone standing near the Mac, with the screen
locked, without authentication.

**Mitigated by:** a 200-character cap, newline flattening via the existing
`sanitizedForDialog`, no actionable controls (`categoryIdentifier` stays
unset), and a description that names the constraint in the model's own terms
("anything you would not put on a postcard"). The durable
`agent_activity_log` row uses the `persistedSummary` override so a
model-authored body is never written to disk forever — the same reasoning
`createAlertRule` already applies to its JSON.

**Unmitigated:** Sentry cannot inspect a body for secrets. A model that
decides to include an API key it just found in `.env` will succeed. The
honest framing is that this is a *prompt-level* control with a length cap
behind it, not an enforcement boundary, and the AI Access pane's copy for this
tool should say what the tool can do rather than implying it is filtered.

**`diagnose_failure`** returns alert firings, which carry user-authored rule
names and bodies. That is not a new exposure — `get_alert_history` already
returns them and is enabled by default — but the new tool should not widen it
(no raw metric dumps beyond the evidence strings a finding cites).

### 7.4 A write tool that surprises the user

**Scenario A: the first notification.** A user enables `notify_user` in AI
Access, forgets, and three days later gets a banner from something calling
itself "Cursor" at 23:40. The mitigations are structural: off by default (it
is a write tool), the client name in the title, quiet hours applying by
default (`agentNotificationsRespectQuietHours = true`), Do-Not-Disturb
inherited from the `AlertEngine` path, and time-sensitive/Focus-breaking
urgency requiring a separate opt-in that is off by default. An agent does not
get to override a Focus mode on day one.

**Scenario B: a guardrail revoking mid-build.** A thermal ceiling (§2.2) that
releases a keep-awake hold during a build the user is watching, and says so
only in a menu-bar feed. Mitigated because the revocation path already
announces twice — `AppDelegate.announceAgentRevocation` posts a notification
*and* writes an `MCPActivityLog` row attributed to "Sentry Guardrails" rather
than to the agent (deliberately: "the agent didn't call `release_awake`,
Sentry released it"). This is also why the thermal ceiling should ship after
`notify_user`, not before: the user should already be accustomed to Sentry
speaking about agent activity before Sentry starts interrupting agent
activity.

**Scenario C: budget enforcement the user cannot explain.** The strongest
argument against the Wh/day budget in §2.3 is exactly this — a denial whose
cause (another application's power draw) is invisible to the person reading
the denial. A guardrail the user cannot predict is one they will turn off, and
they will turn off the *whole* guardrail block to do it.

### 7.5 The two engines disagreeing

A quieter failure mode, but the one most likely to actually ship as a bug: any
new predicate that gates `keep_awake` must also be visible to
`AgentPreflight`, or `preflight_check` will say `proceed` and the very next
`keep_awake` will be denied. The codebase already treats agreement between
these two as a correctness property — `wait_until_ready`'s description
promises it. A thermal ceiling that lives only in `AgentGuardrails.evaluate`
breaks that promise silently, and the agent's recovery from it (retry
`preflight_check`, get `proceed` again, retry `keep_awake`, get denied again)
is a loop.

---

## 8. Summary of the recommended sequence

1. Persist `memory.pressure_percent`, or delete
   `ResourceEventsSummary.peakMemoryPressurePercent` — it is always `nil`
   today. (~half a day, unblocks the memory branch of §3.)
2. `notify_user` + `sentryctl notify` + the plugin `Stop` hook + the skill.
   (~2–2.5 days.) Ship §5's `wattHoursConsumed` in the same change so the
   notification has something worth saying.
3. `diagnose_failure`. (~2–3 days.)
4. Thermal ceiling guardrail, with the matching `AgentPreflight` reason code.
   (~half a day.)
5. Work spans, if the keep-awake leak proves to be a real complaint. (~1–2
   days.)

Not on the list, deliberately: the Wh/day budget, and anything multi-Mac.
