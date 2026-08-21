# Battery features — research and specification

Date: 2026-08-07 · Branch: `research/battery-features` · Status: **research + spec, nothing implemented**

> **EDITOR'S NOTE (2026-08-20): the precedent this document argues from no
> longer exists.** Sentry's fan-control feature — `SentryFanDaemon`, the root
> LaunchDaemon that could write SMC keys, and everything in
> `SentryKit/FanDaemon/` — has been removed. Sentry reads fan speeds and
> never sets them, and the app now ships **no privileged execution at all**.
> Every present-tense reference below to `SentryFanDaemon`, `FanDaemonProtocol`,
> `FanDaemonFailSafe`, `FanDaemonClamp`, `FanDaemonContract`, `FanDaemonTiming`,
> `SMCFanWriter`, or `docs/fan-control-spike.md` (also deleted) describes code
> that is gone; read them as a historical record of a design that shipped once,
> not as a description of this codebase.
>
> This **strengthens** the document's verdict rather than weakening it. §4.1
> argues that the fan daemon's safety bounds do not transfer to charge
> limiting; with the fan daemon deleted, §6's "extend the existing daemon"
> framing is no longer available at all. Building charge limiting would mean
> *introducing* a root helper into an app that deliberately has none — a much
> larger decision than extending one that was already there, and one that has
> to be argued on its own before any of §6 applies.

Probe hardware: **Mac16,8 (MacBook Pro, Apple M4 Pro), macOS 26.6 (build 25G72,
Darwin 25.6.0)**.

This document answers the question "should Sentry ship battery charge limiting,
and what other battery features are worth building". It answers it from
measurements taken on this machine plus current sources, not recollection.
Where a claim is inference rather than observation it says so, in the style
`docs/fan-control-spike.md` already established for the fan work.

---

## 1. Verdict

**Sentry should not ship an SMC-based charge limiter. It should ship a charge
*diagnostics* surface — which nobody else has and Sentry is uniquely placed to
build — plus a control that drives macOS's own limit rather than fighting it.**

### 1.1 Why

**macOS 26.4 (March 2026) shipped the feature.** System Settings ▸ Battery ▸ ⓘ
next to Charging is now a slider at 80 / 85 / 90 / 95 / 100 %. Apple's own
requirement line is "requires macOS Tahoe 26.4 or later and a Mac with Apple
silicon". It comes with a Shortcuts action, a temporary-override flag, an
automatic Desktop Mode, and a gauge-recalibration exemption. Press ran it as
"RIP AlDente". That is the headline feature of the entire category, now free,
on the hardware essentially all of Sentry's laptop users are on.

**Apple's own implementation is entitlement-fenced.** `powerd` carries a full
arbitrary-percentage limit facility — `chargeSocLimitSoc`, `chargeSocLimitOwner`,
`chargeSocLimitToken`, actions `chargeSocLimitChargeLimit` /
`chargeSocLimitChargeOverride` / `chargeSocLimitDrain` — behind the private
entitlement **`com.apple.private.iokit.soc-limit`**, held on this machine by
exactly two binaries: `powerd` and `/usr/libexec/PowerUIAgent` (§3.3). A third
party cannot get it. So every third-party limiter is a bypass of a fence Apple
built, which is why the category's failure modes look the way they do.

**And the bypass is losing.** The public record here is not ambiguous (§2, §4):

- `mhaeuser/Battery-Toolkit` — **archived read-only on 21 March 2026**, three
  days before macOS 26.4 shipped.
- `zackelia/bclm` — dead since `CHWA` vanished in macOS 15.0 beta 5.
- AlDente — a live, five-user thread of "charges past the 80 % limit to 91–93 %"
  on macOS 26.5/M4 ([#1766](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/1766)),
  a 74-comment macOS 27 megathread ([#1771](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/1771)),
  and a years-long tail of "my Mac won't charge after uninstalling"
  ([#367](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/367),
  [#397](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/397),
  [#1146](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/1146)).
- `charlie0129/batt`, the best-maintained free option, lists macOS 27 firmware
  `20457+` as **outright unsupported** and says in its own README that "batt is
  not needed if the built-in range meets your needs".

Every major macOS release has broken charge limiting for every vendor, and
because the Apple Silicon "SMC" is firmware that ships with the OS, **the
breakage is not reversible by downgrading** — AlDente's maintainer confirms
downgrades do not restore function ([discussion #1534](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/discussions/1534)).
This is a treadmill, and it is a two-person project.

**On this specific Mac the relevant keys have already moved.** A read-only
enumeration of all 3 247 SMC keys shows `CHWA`, `BCLM`, `CH0B`, `CH0C`, `CH0I`
**absent**; `CHLS` present but privilege-restricted even for key info; `CHTE`
and `CHIE` present and writable (§3.1). Anyone building this today would be
building against the third key generation in three years.

### 1.2 The honest counter-argument, stated fairly

Apple's limit **starts at 80 %**. A user who wants to hold a desk-bound MacBook
at 60 % cannot do it natively. BatFi's own users make exactly this objection —
*"The native system option starts at 80% — this will not work"*
([BatFi #140](https://github.com/rurza/BatFi/issues/140)) — and Apple's limit
also has no hysteresis band; it resumes charging once the charge drops ~5 %,
where users want "float between 70 and 80".

That gap is real. It is not worth Sentry taking on the treadmill above to
close, when a free GPL tool (`batt`, 10–99 %, with a maintainer who ships
same-day fixes) already covers it. **The right answer is to detect it and say
so** — Sentry can tell a user "this machine sits above 90 % for 94 % of its
life; macOS's limit will get you to 80 %, and here is how" — which is a better
product than a fragile reimplementation.

### 1.3 What Sentry should build instead

The best finding in this whole exercise is that **the highest-value battery
feature in the category is read-only, requires no privilege, and Sentry already
collects the data for it.**

`BatteryCollector` reads `AppleSmartBattery` → `ChargerData` →
`NotChargingReason`. On this machine that reads **4194305 (`0x400001`)**. The
SMC key `CHNC` — the charge-inhibit reason bitfield documented in the Linux
mainline `macsmc-power` driver — reads `01 00 40 00 00 00 00 00`, which is
little-endian **4194305**. They are the same value. **`NotChargingReason` *is*
`CHNC`, and Sentry has been reading it unprivileged since before this document
existed.**

That bitfield answers, authoritatively, the single most-asked question in this
entire product category: *why is my Mac plugged in and not charging?* Is it
Apple's limit? Optimized Battery Charging? Heat? A weak adapter? A third-party
app's gate? Nobody ships this. Sentry can, this week, with no daemon and no
risk. See feature 1 in §5.

Priorities, in order: **charge diagnostics** (new, unique, free), **drive the
OS limit via the public App Intent** (supported, revert-safe), then the
analytics AlDente's own developer concedes they still win on — charge-session
history, adapter diagnostics, heat correlation — where Sentry's GRDB store,
rollups and insight engine are already built and nobody else has an equivalent.

Sentry's advantage over AlDente was never that it could write an SMC key.
Apple just deleted the competitor's headline feature. Sentry should walk into
the space Apple left, not the one it took.

---

## 2. Competitive survey

### 2.1 The reframing event

macOS 26.4, released ~24 March 2026, added the native Charge Limit
([9to5Mac](https://9to5mac.com/2026/02/16/macos-26-4-brings-battery-charge-limit-to-the-mac-and-shortcuts/),
[MacRumors](https://www.macrumors.com/2026/02/16/mac-charge-limit-macos-tahoe-26-4/)).
[TechRadar ran "RIP AlDente"](https://tech.yahoo.com/ai/apple-intelligence/articles/rip-aldente-apple-finally-gives-150202560.html)
— editorial, with no comment obtained from the vendor. Apple's caveat: the Mac
stops within a few points of the limit and will "occasionally still charge to
the full 100 %" to keep the state-of-charge estimate accurate.

What Apple's feature still does not do: go below 80 %, maintain a hysteresis
range, force-discharge, pause on heat, run calibration, or control the MagSafe
LED. Those are the surviving third-party niches.

### 2.2 The limiters

| App | Licence / price | Platforms | Charge limit | Beyond limiting | Health |
|---|---|---|---|---|---|
| **[AlDente](https://apphousekitchen.com/)** (AppHouseKitchen) | Closed; ~11,49 €/yr or 23,99 € lifetime (US listings say $13.99 / $24.99 — regional, unresolved); also Setapp | Intel **and** Apple Silicon; macOS 12+ | Free tier: limit + discharge only | **Pro-gated:** Sailing Mode (hysteresis), Heat Protection, Calibration, Top Up, MagSafe LED, Shortcuts, Schedule, Power Flow Sankey, sleep/close behaviours | v1.38.1 (3 Aug 2026), actively shipped |
| **[Battery Toolkit](https://github.com/mhaeuser/Battery-Toolkit)** (Häuser) | BSD-3, free | Apple Silicon only | Upper limit (floor 50 %), lower limit for hysteresis | Adapter disable / force discharge, MagSafe sync, background-activity pause | **ARCHIVED 21 Mar 2026.** Last release 1.8, Aug 2025. Not notarized. **Do not build on it.** |
| **[batt](https://github.com/charlie0129/batt)** (charlie0129) | GPL-2.0, free | Apple Silicon only | **10–99 %**, upper+lower bounds | MagSafe LED, adapter control, auto-calibration, sleep controls, timed disables | v0.8.0 (21 Jul 2026). Best-maintained in the category — one issue diagnosed, fixed, released and confirmed **in a day**. |
| **[battery](https://github.com/actuallymentor/battery)** (actuallymentor) | MIT, free | Apple Silicon only | True range (`maintain 45-55`) | CLI + GUI | v1.4.0 (Feb 2026), 175 open issues. Broke on 26.4 ([#460](https://github.com/actuallymentor/battery/issues/460), [#461](https://github.com/actuallymentor/battery/issues/461)). HN criticised the installer for piping shell scripts from GitHub into `visudo`. |
| **[BatFi](https://github.com/rurza/BatFi)** (Różyński) | MIT nominally; pay-what-you-want, $10 min commercial | Apple Silicon only | Yes, held indefinitely | **Rule-based automation with schedule *and location* gating** — the most interesting differentiator in the survey | Shipping build (3.1.1) is **ahead of public source** (newest branch commits Mar 2025). Dominant complaint: stuck "initializing" ([#133](https://github.com/rurza/BatFi/issues/133), [#134](https://github.com/rurza/BatFi/issues/134), [#146](https://github.com/rurza/BatFi/issues/146)). |
| **[Energiza Pro](https://appgineers.de/energiza/)** | $1.49/mo, $9.99/yr, $19.99 forever | macOS 10.13+, **MacBooks from 2010** — widest Intel support | Upper + lower thresholds | Heat protection, charge-to-full, discharge (ASi only), halt-on-sleep | The only subscription-first limiter |
| **[bclm](https://github.com/zackelia/bclm)** | MIT, free | Intel `BCLM`; ASi via `CHWA` | — | — | Effectively dead — last release Nov 2023, broke when `CHWA` vanished |

### 2.3 The monitors (no charge control — worth knowing, since Sentry competes here)

- **[coconutBattery](https://www.coconut-flavour.com/coconutbattery/)** — v4.3.3
  (Jul 2026). Free + **one-time** Plus (price could not be verified; third-party
  figures range $12.95–$17.95, all unconfirmed). Health, cycles, temperature,
  capacity snapshots over time, iPhone/iPad reading, Lifetime Analyzer. **The
  least-complained-about app in this survey**, largely because it never touches
  the charging circuit. This is the app Sentry's battery tab is really competing
  with, and the model to beat.
- **[iStat Menus 7](https://bjango.com/mac/istatmenus/)** — ~$11.99 MAS
  (Bjango's own page rendered prices as placeholders). Detailed battery state,
  configurable menu item, battery/power alerts, Bluetooth device levels.
- **[Battery Health 3](https://fiplab.com/apps/battery-health-3-for-mac)** (FIPLAB)
  — one-time, direct sale. Health, live electrical readouts, "Energy Hogs",
  historical charts, iOS monitoring. Price not findable.
- **[Stats](https://github.com/exelban/stats)** (exelban) — MIT, free, 41 k
  stars, pushed 7 Aug 2026. Battery module is monitoring only; its SMC layer
  touches **no charge-control keys at all** (fan/temp/voltage/power only).
- **[Endurance](https://enduranceapp.com/)** — **Magnetism Studios, not Charlie
  Chapman** (the brief's attribution was wrong). $20 one-time. **Not a charge
  limiter** — a runtime extender: Turbo Boost disable, app sleeping, dimming.
  Its headline Turbo Boost feature is **meaningless on Apple Silicon**. No
  version or recent review found; possibly dormant.
- **[Volta](https://volta.garymathews.com/)** — Intel-only undervolting,
  Haswell/Broadwell only. Irrelevant now.
- **[Battery Buddy](https://batterybuddy.app/)** — free emoji menu-bar face. Not
  a monitor.
- **"Bilancia"** — searched repeatedly; **no such macOS battery app found.**

### 2.4 What users actually complain about — the pattern that matters most

1. **Every major macOS release breaks charge limiting, for every vendor.**
   macOS 15.0 (`CHWA` gone), 15.5/15.7 (legacy gates stopped accepting writes),
   26 Tahoe, 26.4, 27 betas. Structural, not a quality problem with any one app.
2. **Firmware changes are sticky across OS downgrades.** The single nastiest
   property in the category ([AlDente #1534](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/discussions/1534)).
3. **"Charges past the limit" is the most common complaint, and it is silent** —
   the app believes it is holding while the menu bar shows a lightning bolt.
4. **It can leave a Mac unable to charge.** AlDente #367, #397, #1146,
   [discussion #983](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/discussions/983)
   ("Why resetting the SMC and NVRAM don't work after uninstalling"). Bounded —
   no credible report of permanent damage — but real and recurring.
5. **Conflict with Apple's limit is confirmed, not theoretical.**
   [AlDente #1749](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/1749):
   a user with AlDente set to 100 % found the Mac stuck at 80 % because macOS's
   own limit was set to 80 %. The gates are independent and **both must be open
   for charging to occur, so the effective ceiling is whichever is lower.**
   Every vendor now tells users to turn Optimized Battery Charging off and set
   the macOS limit to 100 % — i.e. to disable the OS feature to make theirs work.
6. **Helper/daemon installation is a permanent tax** — repeated admin prompts
   ([AlDente #1740](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/1740),
   #1751), install loops, incomplete uninstalls.
7. **App overhead is a live complaint, and it is a warning for Sentry
   specifically.** AlDente writes **~0.5 GB/day** re-journaling a 2.5 MB SQLite
   file — 7.24 GB over 14.7 days
   ([#1797](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/1797),
   [#1256](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/1256)),
   which spawned a request for an "AlDente Lite: just flip the flag, no
   monitoring, no sqlite". **Sentry also has a GRDB/SQLite store on a polling
   loop.** Worth an explicit check of Sentry's own write amplification before
   adding per-second battery rows; `HistoryStore.record` already documents a
   write-amplification fix, so the awareness exists — this is a reason to keep
   it.
8. **Nobody credibly documents battery drain from the apps themselves.**
9. **No vendor says "you don't need us."** The closest is `batt`'s README. The
   sentiment comes from users: *"I bought BatFi but since macOS 26.4, I don't
   need it anymore"* ([#140](https://github.com/rurza/BatFi/issues/140)).

---

## 3. Mechanism: what is actually true today

### 3.1 SMC keys — measured on this Mac, cross-checked against source

Method: read-only probe (`READ_INDEX` 8, `READ_KEYINFO` 9, `READ_BYTES` 5 —
**no `WRITE_BYTES`**), 80-byte `SMCParamStruct`, selector 2, same protocol layer
as `SystemMetricsKit/Bridges/SMCFanBridge.swift`. Run unprivileged. `#KEY`
reports **3 247 keys**, all 3 247 enumerable by index, so "absent" below means
absent from this SMC's key table — result `0x84`, key-not-found — and not merely
unreadable.

| Key | Purpose (per source) | Mac16,8 / macOS 26.6 |
|---|---|---|
| `BCLM` | Intel firmware charge ceiling, `ui8` %. Survives shutdown. **Intel only** | **Absent** |
| `BFCL` | Intel final charge level | **Absent** |
| `CHWA` | Apple Silicon **boolean flag** — `1` = fixed 80 % end / 75 % start. **Not a percentage** | **Absent** |
| `CH0B` `CH0C` `CH0I` | Legacy inhibit / adapter-disable gates | **Absent** |
| `CH0J` | Adapter disable (legacy) | In index, **key info zeroed** to an unprivileged caller |
| **`CHLS`** | **`ui16` arbitrary end threshold** (low byte, min 10; start = end − 5). Bit `0x100` = force discharge | **In index, key info zeroed** to an unprivileged caller |
| **`CHTE`** | Charge-inhibit gate — write `01 00 00 00` to inhibit | **Present**, `ui32`, attr `0xd4` (**writable**), reads `0` |
| **`CHIE`** | Force discharge — write `0x08` | **Present**, `hex_` 1 B, attr `0xd4` (**writable**), reads `0` |
| **`CHNC`** | **Charge-inhibit reason bitfield, `u64`** | **Present**, reads `01 00 40 00 00 00 00 00` = **4194305** |
| `CH0R` | Power-input status bitfield, `u32` | Present, reads `0` |
| `CHSC` | System charging flag | Present, `ui8`, reads `0` |
| `ACLC` | **MagSafe LED colour** — `0x03` = green, `0x04` = orange, `0x06/07` = blink | Present, writable, reads **`3` (green)** — machine is fully charged ✓ |
| `BRSC` | Claimed "relative state of charge" | Present, `ui8`, reads **`100`** at 100 % SoC |
| `CHBI` | Claimed "battery charging current" | Present, `ui32`, reads `0` |

**The decode is validated, not assumed.** Independent cross-checks against
`AppleSmartBattery` IORegistry on the same machine at the same moment:

| SMC key | Raw | Decoded | IORegistry | |
|---|---|---|---|---|
| `CHNC` | `01 00 40 00 …` | 4194305 | `NotChargingReason` 4194305 | ✓ |
| `CHAS` | `70 0f 00 00` | 3952 | `ChargerConfiguration` 3952 | ✓ |
| `CHBV` | `4b 11 00 00` | 4427 | `ChargingVoltage` 4427 | ✓ |
| `B0CT` | `98 00` | 152 | `CycleCount` 152 | ✓ |
| `B0FC` | `32 16` | 5682 | `AppleRawMaxCapacity` 5682 | ✓ |
| `B0AV` | `47 33` | 13127 | `Voltage` 13127 mV | ✓ |

The probe is not misreading. The keys that are absent really are absent.

**`CHNC` = `NotChargingReason`.** This is the load-bearing discovery of the
whole exercise and it deserves its own paragraph. The Linux mainline
`drivers/power/supply/macsmc-power.c` documents `CHNC` as the charge-inhibit
reason bitfield: **bit 0** battery full, **bit 7** no charger, **bit 14** `CH0C`
gate, **bit 15** `CH0B`/`CH0K` gate, **bit 18** battery-full-2, **bit 23** BMS
busy, **bit 24** `CHLS_LIMIT`, **bit 53** `NOAC_CH0J`, **bit 54** `NOAC_CH0I`.
`OpenDente` reads bit 24 specifically to detect macOS 26.4's native limit.
Sentry's `BatteryCollector` already reads the identical value out of
IORegistry, **unprivileged, today**, and currently discards it — its
`notChargingReasonText` handles only bits 0 and 1 and falls back to "Charging
on hold" for everything else, with a code comment noting it observed exactly
this `0x400001` and could not explain the high bit. That high bit is bit 22,
which is **not** in the Linux list; it remains unidentified (§7).

**Confidence and its limits, stated the way the fan spike states them.** This
is **one machine**. It is current (M4 Pro, macOS 26.6, August 2026), which is
what makes it worth acting on, but a single-hardware result cannot separate
"the M4 generation never had these keys" from "macOS 26.4 removed them fleet-
wide when Apple shipped its own limit". The corroborating evidence points at
the second: `actuallymentor/battery` had to add "Tahoe SMC keys" (`CHTE`,
`CHIE`) in [PR #388](https://github.com/actuallymentor/battery/pull/388)
because the legacy gates stopped accepting writes, and a device log in
[issue #448](https://github.com/actuallymentor/battery/issues/448) reads
`tahoe=true legacy=false CHIE=true CH0I=false` on a MacBook Air M4 / macOS 26.3
— the same shape as this machine.

**Either explanation is fatal to shipping an SMC limiter**, for different
reasons: under the first, the feature silently does nothing on the newest and
most expensive Macs; under the second, it works today and stops working at the
next point release on every machine at once — which is the worst failure shape
a paid, notarized app can have.

**Unresolved value disputes — do not put a single canonical value in code.**
Independent implementations disagree: `CH0C` inhibit is `0x01` (Linux,
Battery Toolkit) or `0x02` (batt, actuallymentor); `CH0J` disable is `0x01`
(batt, actuallymentor) or `0x20` (Battery Toolkit). Linux defines
`CH0X_CH0C = BIT(0)` and `CH0X_CH0B = BIT(1)`, i.e. these are bitmasks of
inhibit *sources*, which is probably why both work. Unresolved.

`CHTE` and `CHIE` are writable and read zero on this machine, and per three
independent codebases they are the current gates. **That is enough to know what
they are and not enough to write to them**: nothing here has been verified on
hardware from this branch, and writing to a live charging controller on someone
else's machine on the strength of three GitHub repos is exactly what
`FanDaemonContract` was written to prevent.

### 3.2 What macOS itself now provides

Verified on this machine from Apple's shipping binaries and string tables.

**Charge Limit (macOS 26.4+, Apple Silicon).** A slider, not a toggle. From
`PowerPreferences.appex`: symbols `ChargeLimitSlider`, `chargeLimitLevel`,
`manualChargeLimit`, `optimizedChargeLimit`; strings
`MAC_CHARGE_LIMIT_DESCRIPTION` = "Your Mac will charge to %@ limit.",
`MAC_CHARGE_LIMIT_TO_FULL` = "Set Limit to %@",
`MAC_CHARGE_LIMIT_OVERRIDE_DESCRIPTION` = "Charge limit will return to %@ at
%@."; capability gate `DeviceSupports80ChargeLimit` (also in
`/usr/libexec/PowerUIAgent`). Steps are 80/85/90/95/100 %. Resumes charging if
the charge drops more than ~5 % — which matches `CHLS`'s fixed −5 start offset
exactly, and is the strongest hint that `CHLS` is the mechanism (§7).

**Desktop Mode.** `DESKTOP_MODE` = "Desktop Mode",
`DESKTOP_MODE_TEXT` = "Rarely used on battery",
`MAC_CHARGE_DESKTOP_MODE_HEADER` = "Your Mac will stay at %@ while connected to
power for extended periods of time to prolong battery lifespan." This is,
exactly, the use case that sold third-party limiters. The OS now detects it and
does it automatically.

**Gauge-recalibration exemption.** `MAC_GAUGING_MITIGATION_HEADER` = "Your Mac
will occasionally charge to %@ even if the charge limit is set below %@", plus
`PowerD-BatteryGaugingMitigation` and the log string "Battery gauging mitigation
flag and fixed limits are enabled." This matters twice. It explains a recurring
third-party complaint (users see a charge above their cap and assume the app
broke). And it is a *correctness* feature a hard third-party inhibit cannot
replicate: a cap that never lets the pack reach full starves the gas gauge of
the transitions it recalibrates from, so reported percentage and health drift.
Sentry's own `BatteryNeverExercisedRule` already explains this in prose; Apple
now fixes it in the mechanism.

**Optimized Battery Charging.** Since macOS 10.15.5 (2020). `SC_TEXT_FMT` = "To
reduce battery aging, your Mac learns from your daily charging routine so it can
wait to finish charging past %@ until you need to use it on battery"; plus
`SC_TEMP_DISABLE` = "Turn Off Until Tomorrow". Adaptive, not a limit.
**There was no built-in hard charge limit on Mac before 26.4** — the widely
repeated "80 % toggle on M3 MacBooks" is iPhone folklore misapplied to the Mac.

**Slow-charger diagnostics.** `MAC_SLOW_CHARGER` = "Slow Charger", linking to
`support.apple.com/102397`. Binary; Sentry can quantify it (§5, feature 4).

**Battery history UI.** `BATTERY_LEVEL_GRAPH_TITLE`, `ENERGY_USAGE_GRAPH_TITLE`,
`SCREEN_ON_USAGE_GRAPH_TITLE`, `DAILY_GRAPH_TITLE_FMT` = "Last %@ Days". Worth
knowing before proposing "battery level history" as a Sentry feature — the OS
ships a version. Sentry's edge is retention, correlation and export, not the
graph.

**Not present:** no Mac equivalent of iOS 26's Adaptive Power Mode was found.
macOS 26 has Low Power / Automatic / High Power, per power source.

### 3.3 How Apple implements it — and why third parties cannot

`powerd` (`/System/Library/CoreServices/powerd.bundle/powerd`) carries a full
charge-limit vocabulary: `chargeSocLimit`, `chargeSocLimitSoc`,
`chargeSocLimitOwner`, `chargeSocLimitToken`, `chargeSocLimitReason`,
`chargeSocLimitAction` with values `chargeSocLimitChargeLimit`,
`chargeSocLimitChargeOverride` and **`chargeSocLimitDrain`**, plus
`chargeLimitEndSoc`, `disableSocLimitPolicy`, "Failed to activate SOC limit: %d"
and "SOC limit policy suspend due to mitigation active:%d".

So the OS has a first-class, arbitrary-percentage state-of-charge limit with an
owner/token model, an override action, **and a drain action** — force discharge
is something macOS itself does.

`codesign -d --entitlements -` shows **`com.apple.private.iokit.soc-limit`** on
exactly two binaries: `powerd` and `/usr/libexec/PowerUIAgent`. Not obtainable
by a third-party developer. **There is a correct, supported, arbitrary-percentage
charge limit API on macOS and Apple has fenced it off.** Everything the
third-party apps do is a bypass of that fence.

The persisted state lives in `/Library/Preferences/com.apple.powerd.charging.plist`
— world-readable, holding an `NSKeyedArchiver`-encoded `policies` array (empty
on this machine, which has no limit set). A *possible* read path for "is a limit
in effect", in a private format that can change without notice. §5 treats it as
a fallback behind `CHNC`, not a foundation.

### 3.4 The supported third-party path: the App Intent

From `ActionKit.framework`'s App Intents metadata
(`Metadata.appintents/extract.actionsdata`):

```
action:  SetBatteryChargeLimitAction
title:   "Set Battery Charge Limit"
descr:   "Sets the battery charge limit of the device."
availability: macOS 26.4, iOS 26.4, watchOS 26.4 (visionOS: obsoleted)
authenticationPolicy: 0        (no authentication required)
openAppWhenRun: false          (runs in background)
supportedModes: 1
parameters:
  limit            : entity ChargeLimit — "The battery charge limit percentage to set."
                     (options resolved at runtime by ChargeLimitsQuery — the
                      device decides which percentages it offers)
  setUntilTomorrow : Bool, default false — "When enabled, the battery charge
                     limit will be reset to its previous value on the following day."
```

Design consequences:

- **There is no matching read intent.** `SetBatteryChargeLimitAction` is the
  only battery action in `ActionKit`'s table. Sentry can set through this path
  but must read back some other way — which is what makes `CHNC` (§3.1) the
  right read source.
- `setUntilTomorrow` is "top up before a trip", already built by Apple.
  Michael Tsai reports the restore fires at 6 AM and complains it cannot be held
  longer ([mjtsai.com](https://mjtsai.com/blog/2026/02/28/macos-26-4-charge-limit-and-shortcuts/)).
- Third-party apps cannot execute another target's App Intent directly. The
  reachable mechanism is Shortcuts: `shortcuts://run-shortcut?name=…` — which
  Sentry already uses at `Sentry/App/AppDelegate.swift:538` — or
  `/usr/bin/shortcuts run` (present on this machine). This costs a one-time
  user setup step: the user creates a shortcut wrapping the action. That
  friction is real and is the main cost of this route.

### 3.5 Force discharge while plugged in

Achievable on Apple Silicon — `CHIE = 0x08` on current firmware, `CH0I`/`CH0J`
on older, `CHLS` bit `0x100`. It does not dump charge into a load; it disables
the adapter input so the system runs off the pack while physically plugged in.

Two hard constraints worth knowing regardless of the verdict:

- **Clamshell mode breaks it.** With the lid closed and AC apparently removed,
  macOS sleeps immediately. Documented macOS behaviour, not a bug — Battery
  Toolkit and batt both ship sleep-inhibition workarounds for it.
- **Capability is per-firmware and must be probed**, not assumed
  ([actuallymentor #448](https://github.com/actuallymentor/battery/issues/448)
  shows `CH0I=false` on an M4 Air).

**Recommendation: do not build this, under any verdict.** It is the most
dangerous item in the space and the least valuable. It turns "the app leaked a
setting" into "the machine is actively draining while the user believes it is
charging", it generates heat at the state of charge where heat is worst, and
unlike a ceiling there is no natural floor — a leaked discharge gate ends at
0 %. The only legitimate use is calibration, and Apple's gauge-recalibration
exemption (§3.2) now covers that in the mechanism. No documented hardware
damage from it — the risk is stranding, not destruction.

### 3.6 Is SMC writing from a root daemon still possible?

**Yes, as of macOS 26.x.** batt, AlDente, `battery` and OpenDente all ship
working root helpers on Tahoe. The mechanism is unchanged for a decade:
`IOServiceMatching("AppleSMC")` → `IOServiceOpen` → `IOConnectCallStructMethod`
with an `SMCParamStruct`. No entitlement, no kext, no DriverKit, no SIP
disable — just root. This is exactly what `SentryFanDaemon` did, before it was
removed; nothing in Sentry does it now.

**One widespread claim is folklore and should not be repeated.** `zackelia/bclm`'s
README says it fails on macOS ≥ 15 "due to new entitlement enforcement from the
kernel that cannot be circumvented without disabling SIP". The observed error
was `keyNotFound(CHWA)` — the key was *absent*, not blocked — and every other
tool kept working by switching key sets. Relatedly, `e00002bc` is
`kIOReturnError`, the generic IOKit error, **not** a privilege error
(`kIOReturnNotPrivileged` is `0xe00002c1`). Do not build an "Apple blocked us
with entitlements" narrative on that code.

**But Apple is gating individual keys.** `CHLS` key info comes back zeroed to an
unprivileged caller on this machine, and `smc-cli` reports an outright
`(iokit/common) privilege violation` reading it. The direction of travel is not
a lockout — it is making the bypass pointless: enforcement moves into firmware
(`CHWA` → `CHLS` → the `bf*` family), Apple's UI becomes the intended front
end, and the imperative gates third parties depend on get renamed each firmware
cycle. Expect erosion, not a door slamming.

---

## 4. Risks, failure modes, and required safeguards

Written as if §1 were overridden and an SMC limiter were built anyway, because
that is when it is needed.

### 4.1 The asymmetry with fan control, which is the core argument

(Written while fan control still shipped; see the editor's note at the top.
The asymmetry stands, and the fan side of the comparison is now history.)

`FanDaemonFailSafe`'s doc comment bounded the fan feature's worst case with two
facts: the SMC's firmware takes back over on a power cycle, and the daemon never
writes below `F{i}Mn`, so a leaked override "cannot park a fan under the floor
the firmware itself considers safe". **Neither bound has an analogue here.**

| | Leaked fan override | Leaked charge inhibit |
|---|---|---|
| How the user notices | Immediately — the fans are audibly wrong | Not for hours or days |
| Natural floor | `F{i}Mn`, read from the SMC | **None.** A machine that will not charge goes to 0 % |
| Recovery | Power cycle; always available | Power cycle needs enough charge to boot — the thing that was taken away |
| Worst realistic outcome | A loud or warm Mac | A user at 4 % in an airport with no idea why |

That table is the verdict in another form. The fan daemon's safety argument does
not transfer, and a design that reused its shape without reproducing its bounds
would be borrowing the reassurance without the substance.

### 4.2 Enumerated failure modes

1. **App crashes or is `SIGKILL`ed mid-limit.** Genuinely well handled by the
   existing heartbeat (15 s to revert). What is not handled is the *daemon*
   being `SIGKILL`ed — no handler runs. For fans that leaves noise; here it
   leaves a machine that will not charge, with no process left that knows it
   did that.
2. **Reboot.** On Apple Silicon a reboot **is** an SMC reset: the imperative
   gates (`CHTE`/`CHIE`/`CH0*`) do **not** survive it, and every tool re-applies
   on login. Firmware-enforced limits (`CHWA`/`CHLS`/`bf*`) **do** survive.
   Which class a given write falls into determines the entire revert story, and
   it changes per firmware generation.
3. **Sleep and hibernation.** Imperative gates persist as last written through
   sleep, so a daemon suspended at the wrong moment overshoots — this is the
   mechanism behind the "charges past the limit" complaints. **Mac firmware
   resets SMC keys after hibernation**, so batt loses control entirely there.
4. **Shutdown with the charger attached.** **Apple Silicon charges to 100 %,
   period.** No software limiter controls the charge state while the machine is
   off. (Intel + `BCLM` does hold — AlDente sells exactly this on Intel.)
   Behaviour of `CHLS`/`bf*` when shut down is **unverified**.
5. **macOS/firmware updates.** §2.4 item 1–2. The dominant failure mode, not
   reversible by downgrade.
6. **Unsupported model.** On this M4 Pro the classic keys are gone entirely, so
   the honest answer is "unsupported" for a large slice of the current fleet.
7. **Conflict with the OS's own limit — confirmed, not theoretical.** The gates
   are independent and both must be open; the effective ceiling is the lower.
   [AlDente #1749](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/1749)
   is the clean case. The industry workaround is to tell users to turn Apple's
   feature off, which is a bad thing to have to ask.
8. **Gauge drift.** §3.2. A hard cap with no recalibration exemption degrades
   the accuracy of the very numbers Sentry displays — health %, time-to-empty.
   Sentry's limiter would degrade Sentry's own dashboards.
9. **Silent overshoot.** The most-reported symptom in the category: the app
   believes it is holding, the hardware is charging, and nothing reconciles the
   two. **Readback is not optional** (§4.4 item 4).

### 4.3 Legal and support exposure

- **Warranty.** I found no authoritative Apple statement that a third-party
  charge limiter voids the warranty, and I will not invent one. What is true and
  sufficient: writing undocumented registers on the charging controller is
  outside anything Apple supports, and if a battery or charger fault follows,
  the app is the first suspect in a support thread even when innocent.
- **Support load.** This feature generates messages shaped like "my Mac won't
  charge" — the highest-anxiety, lowest-patience category a paid Mac app
  receives. AlDente, with a full-time maintainer, is visibly struggling with it.
- **Notarization.** Not a gating issue; the app already ships a root
  LaunchDaemon and is notarized. The exposure is reputational and practical.

### 4.4 Safeguards that would be mandatory

All of these, not a subset:

1. **A hard floor in the daemon**, from the daemon's own SoC read: never inhibit
   below a compiled-in floor, and unconditionally release below a compiled-in
   emergency floor regardless of what the client asks.
2. **Release-on-start.** Clear any inhibit found at startup, before serving
   anything — the only recovery from a `SIGKILL`ed predecessor.
3. **Probe keys at runtime; never hardcode a key set.** Refuse — never guess —
   when the allowlisted keys are absent, mirroring `FanDaemonClamp`'s "refusing
   beats clamping when the range is unknown". Key *set* is chosen by **firmware
   version, not macOS version**: batt's own comment notes newer firmware can
   land on older macOS.
4. **Readback verification.** After the write, poll charging state and SoC, and
   report `accepted` and `applied` as two distinct booleans, exactly as
   `FanDaemonProtocol.setTarget` already does. This is the direct countermeasure
   to §4.2 item 9.
5. **Read `CHNC` and `CH0R` and surface whose gate is holding** — including
   Apple's (bit 24). Never fight a gate silently.
6. **Heartbeat lease**, reusing `FanDaemonTiming` unchanged.
7. **A visible, permanent indicator** whenever a limit is held. A silent
   hardware state is how users get stranded.
8. **Measured answers to §4.2 items 2–4 on real hardware, per model
   generation**, before shipping.

---

## 5. Prioritised feature list

Effort: **S** ≈ days, **M** ≈ 1–2 weeks, **L** ≈ a month or more. "EXTENSION"
names the existing Sentry component it grows out of; "NEW" means no existing
home.

### Tier 1 — build these

**1. "Why isn't it charging?" — charge-inhibit diagnostics.**
*What:* Decode `NotChargingReason`/`CHNC` properly and say, in plain language,
which gate is holding charge: battery full · macOS Charge Limit (bit 24) ·
Optimized Battery Charging · too hot · no charger · adapter insufficient ·
BMS busy · a third-party app's gate (bits 14/15) · unknown bit *n*. Surface it
in the dropdown, dashboard, `get_battery_status`, and as an alert condition.
*Why:* It is the single most-asked question in this entire product category and
**nobody ships an answer.** It is also the honest way to compete with AlDente:
where AlDente writes the gate, Sentry explains it.
*Status:* **EXTENSION**, and cheaper than it sounds — `BatteryStats
.notChargingReason` and `BatteryCollector`'s `ChargerData["NotChargingReason"]`
**already read this exact value, unprivileged** (§3.1). The work is a bit-
decoding table and copy. `notChargingReasonText` currently handles bits 0 and 1
and gives up; the Linux mainline `macsmc-power` bit definitions fill most of the
rest.
*Effort:* **S.** *Risk:* Very low — read-only. The one discipline required is
the one the existing code already shows: **name unknown bits as unknown** rather
than guessing (this machine sets bit 22, which is not in any list I found).

**2. Charge-limit control that drives macOS's own limit.**
*What:* A control in Settings ▸ Battery, the menu bar, and MCP that sets the OS
charge limit via the `Set Battery Charge Limit` App Intent through a Shortcut,
with guided one-time setup. Includes `setUntilTomorrow` as a "top up for a trip"
button. Reads back through feature 1, not through the intent (there is no read
intent).
*Why:* The headline feature users ask for, with Apple owning every part that can
go wrong — persistence, model gating, recalibration exemption, sleep/wake,
shutdown, revert.
*Status:* **EXTENSION** — `AlertAction.runShortcut(name:)` and
`AppDelegate.swift:538`'s `shortcuts://run-shortcut` plumbing already exist;
`MCPTool` gains a write tool beside `keep_awake` / `set_refresh_interval`,
inheriting the existing confirmation gate and per-client rate limiting.
*Effort:* **S–M.** *Risk:* Low. Costs: setup friction (§3.4), a macOS 26.4 floor,
and the honest caveat that the OS cannot go below 80 % (§1.2). Verify the
transport does not steal focus before shipping (§7).

**3. Charge-session history.**
*What:* A record per charge/discharge session — start/end SoC, duration,
adapter, peak pack temperature, average charge watts, which gate ended it — with
a browsable list and detail view.
*Why:* The analytics AlDente's developer concedes they still win on and Apple
does not offer at all. It is where Sentry's store is already better than
anyone's.
*Status:* **EXTENSION**, and unusually cheap — `Migrations.swift:49` **already
creates a `battery_event` table** (`ts`, `kind`, `payload_json`; "Discrete
events, not time-series. Kept forever, tiny.") that **nothing in the codebase
reads or writes.** The hook is sitting there unused. Session segmentation reuses
`InsightAggregates`' daily high/low machinery.
*Effort:* **M.** *Risk:* Low — but see §2.4 item 7 and keep an eye on write
amplification; discrete events are the right shape precisely because they are
not per-tick rows.

**4. Adapter and charging diagnostics.**
*What:* "This 30 W adapter is delivering 18 W; 4 h to full" · "charging is
thermally limited right now" · "this adapter is underpowered for this Mac" ·
adapter identity history.
*Why:* Concrete, actionable, entirely from data already collected —
`adapterRatedWatts`, `adapterDescription`, `adapterCount`, `chargingWatts`,
`isThermallyLimited`. macOS ships only a binary "Slow Charger" label; Sentry can
quantify it.
*Status:* **EXTENSION** — `BatteryStats`, `HardwareInsightRules`,
`EnergyReportCard`.
*Effort:* **S–M.** *Risk:* Low.

**5. Battery alert-rule presets.**
*What:* "Charge above 90 % for 12 h" · "pack above 35 °C while charging" ·
"health dropped a point" · "cycle count crossed *n*" · "adapter under *x* W" ·
"charging held by an unexpected gate".
*Why:* Turns the insight rules — which are retrospective — into something that
fires when it matters.
*Status:* **EXTENSION** — `AlertRule` already supports `MetricID`, comparison,
`sustainedFor`, `cooldown`, `quietHours` and `Precondition.charging` /
`.pluggedIn` / `.onBattery`, so every one of these is expressible today; they
are configurations, not code.
*Effort:* **S.** *Risk:* Low.

### Tier 2 — worth doing, less urgent

**6. Heat-during-charge correlation.** Charge-session temperature curves; "this
battery runs 6 °C hotter charging on the sofa than on the desk".
**EXTENSION** — `ChargingWhileHotRule` and `BatteryTemperatureExposureRule`
exist and are prose-only; this gives them charts and per-session evidence.
**M**, low risk.

**7. Calibration guidance — guidance, not automation.** Detect a stale gas gauge
(long stretches with no full-to-low transition) and walk the user through a
manual calibration; show a "gauge confidence" qualifier on the health figure.
**EXTENSION** — `BatteryNeverExercisedRule` already detects exactly this and
already gives this advice. **S–M**, low risk. **Do not automate the discharge
half** (§3.5).

**8. Health-forecast presentation.** Surface `BatteryHealthForecast` more
prominently with the uncertainty it already models, plus cycle-rate projection
against the 1 000-cycle rating. **EXTENSION** — `BatteryHealthForecast`,
`CycleBurnRateRule`, `BatteryHealthTrendCard`. **S**, low risk provided the
`.insufficientData` / `.stable` honesty rules stay intact.

**9. Time-on-battery and runtime statistics.** "You averaged 5 h 20 m of real
battery use per day this month"; observed Wh/hour by workload; a *measured*
runtime estimate rather than a predicted one. **EXTENSION** —
`EnergyIntegrator` (already watts→kWh with a sleep-aware gap cap) over
`HistoryStore` rollups. **M**, low risk.

**10. Location- and schedule-aware suggestions.** BatFi's genuinely best idea
(§2.2) — "you're at the office, where this Mac is plugged in 94 % of the time;
want the limit at 80 %?"
> **NOTE (Aug 13, 2026):** `LocationService` and every trace of location
> code were deleted with the Location Log cut, and the shipped privacy
> policy + App Privacy label now promise zero location collection.
> Implementing this item means rebuilding that foundation AND redoing the
> permission/manifest/policy paperwork — it is no longer an extension, and
> its cost estimate below is stale.

**EXTENSION** — `ProtectionInsightsEngine` (location layer would need rebuilding). **M→L** with the paperwork.
As a *suggestion* layer over feature 2, not an autonomous actuator.

### Tier 3 — explicitly not recommended

**11. SMC-based charge limiting.** §1, §3.1, §4. Reconsider only if all of:
a supported key set is *measured* on multiple current models; §4.2 items 2–4 are
measured; and every §4.4 safeguard is built. The design is in §6 so the thinking
is not lost.

**12. Force discharge / sailing / discharge-to-X.** §3.5. No.

**13. MagSafe LED control.** `ACLC` is present and writable here (reads `3` =
green, correct for a charged machine), and the value table is well documented.
It is also a cosmetic root write with no safety story and no user value beyond
novelty — and it is the first thing that disappears on macOS 27-era firmware.
Not worth widening a root process's attack surface for.

**14. Rebuilding battery-level / energy graphs to match System Settings.** The
OS ships these (§3.2). Compete on retention, correlation and export.

---

## 6. If charge limiting were built: extending `FanDaemonProtocol`

> Superseded by the editor's note at the top: `FanDaemonProtocol` and the
> daemon that implemented it were deleted. This section is kept as the record
> of what the extension would have looked like, and as the inventory of
> safety machinery any *new* privileged helper would have to reproduce from
> scratch.

Written per the brief as the design that would be correct *if* §1 were
overridden. Its good parts — the allowlist, the deadman floor, release-on-start,
gate attribution — are worth lifting into any future implementation.

### 6.1 The non-negotiable: no generic SMC write

`FanDaemonProtocol`'s doc comment states it directly: "no method takes an SMC
key name, a byte payload, a file path, a command line, or a range … There is no
way to express 'write this value to that key' through this protocol, so a client
that fully compromises the connection still cannot reach an arbitrary SMC
register." `FanDaemonContract` says the same of the vocabulary: "A client cannot
ask this daemon to write `CH0B` or to poke an arbitrary address."

**Any proposal that adds `writeSMCKey(_:bytes:)`, or a charge method carrying a
key name, or a raw `Data` payload, is wrong and should be rejected at review.**
It would not be an incremental loosening; it would delete the single property
that makes a root process with this reach defensible — and it would do so in the
same release that gave that process authority over whether the machine charges.
Say it out loud in review: **the narrowness is the security design.**

The temptation is unusually strong here and worth naming. Because the key set
changes every firmware generation (§3.1), a generic write API looks like
future-proofing — "then we can support new keys without shipping a daemon
update". That argument is exactly backwards: the reason the key set keeps moving
is the reason a human must review each new key, on hardware, before a root
process writes it.

### 6.2 The shape

Three methods. The percentage is an `Int`; the daemon maps it to keys and bytes
from a table compiled into the daemon binary. The client never names a key,
never supplies a byte, never supplies a bound.

```swift
/// Charging capability as the *daemon* determined it, at daemon start, from
/// its own SMC probe and firmware-version read. JSON-encoded
/// `ChargeDaemonDescription`.
///
/// Separate from `describe` rather than folded into it: a Mac with fans and no
/// usable charge keys is the common case (§3.1), and one call that half-
/// succeeds is how "unsupported" becomes indistinguishable from "broken".
func describeCharging(reply: @escaping (Data?, String?) -> Void)

/// Requests a charge ceiling. `percent` is re-validated against
/// `ChargeCeilingAllowlist` — a fixed, compiled-in set with a hard floor — and
/// against the daemon's own state-of-charge read.
///
/// - Parameter reply: `(writtenPercent, wasClamped, verifiedApplied,
///   failureMessage)`. `writtenPercent` is `-1` on failure and callers check
///   `failureMessage` first, matching `setTarget`. `verifiedApplied` answers
///   the separate question of whether charging was *observed* to stop — which
///   the SMC accepting a write does not prove, and which is the direct
///   countermeasure to the category's most common complaint (§4.2 item 9).
func setChargeCeiling(percent: Int, reply: @escaping (Int, Bool, Bool, String?) -> Void)

/// Releases the ceiling. Idempotent: releasing when nothing is held succeeds
/// and writes nothing, for the same reason `returnToFirmware` is idempotent.
func releaseChargeCeiling(reply: @escaping (Bool, String?) -> Void)
```

`heartbeat` is reused unchanged. A ceiling is a lease on exactly the terms a fan
hold is: `heartbeatInterval` (5 s) to keep it, `heartbeatTimeout` (15 s) to lose
it, `idleExitAfter` (60 s) before the daemon gives up and exits.

`ChargeDaemonDescription` reports, at minimum: whether the model is supported,
which key generation the daemon detected, the SoC as the daemon read it, whether
the daemon currently holds a ceiling, and **the decoded `CHNC` gate attribution**
— so the app can say "your ceiling is set to 80 % but macOS's own limit is
holding at 80 % too" instead of two systems silently disagreeing (§4.2 item 7).

### 6.3 What enforces narrowness

**`ChargeCeilingAllowlist`** — a new pure type in `SentryKit/FanDaemon/`
alongside `FanDaemonClamp`, obeying that directory's rule that everything in it
is pure and exhaustively testable on a machine that cannot register a daemon:

- A **closed set of permitted percentages** (`[60, 70, 80, 85, 90, 95]` —
  overlapping Apple's steps, and deliberately *not* a free integer). A narrow
  value space is itself a safeguard: a bug that produces a wild number cannot
  express it.
- An **absolute floor** below which no ceiling may be set, ever, whatever the
  client asks.
- An **emergency-release floor** on observed SoC: below it, the ceiling is
  released and the request refused. A client asking to inhibit charging on a
  nearly-flat battery is either confused or hostile, and the answer is the same
  either way.
- **Refuse, never substitute**, when the SoC read fails — `FanDaemonClamp`'s
  reasoning transferred verbatim: "no readable limits, so write the request
  through unchanged" is the single most dangerous line the feature could contain.

**`ChargeKeyTable`** — the key/value mapping, compiled into the daemon target
only and never into `SentryKit`, preserving the property `SMCFanWriter`'s doc
comment relies on: `Sentry.app`'s own binaries contain no code path that can
write an SMC key, and an auditor can verify it by grepping for the write command
byte. Selected by **firmware version**, not macOS version (§4.4 item 3). A
firmware with no entry yields "unsupported" from `describeCharging` and a
refusal from `setChargeCeiling`. Given §3.1's unresolved value disputes, any
entry whose value is contested across implementations does not go in the table
until it is measured.

**`FanDaemonCommand`** gains three cases and `FanDaemonRefusal` gains
`ceilingNotAllowed`, `chargeKeysUnavailable`, `firmwareUnsupported`,
`stateOfChargeUnreadable`, `stateOfChargeTooLow`. Those enums exist precisely so
"a fourth capability cannot be added without a reviewer seeing a new case appear
here" — a property to pay for, not bypass.

**Naming.** `SentryFanDaemon` would no longer be a fan daemon. Either rename it
(with the launchd label, `SMAuthorizedClients` and
`FanDaemonPeerGate.clientRequirement` churn that implies) or ship a **second,
separate daemon**. The second daemon is better despite the duplication: it keeps
each root process's compile surface and vocabulary minimal, it lets a user
install fan control without granting charge control, and a defect in one cannot
be reached through the other. `FanDaemonContract` already argues for tiny
compile surfaces; two small daemons honour that better than one that does both.

### 6.4 Revert on everything

`FanDaemonFailSafe` already handles most of this correctly and generalises with
a second held-resource field beside `heldFans`. What follows is what must be
*added*, because §4.1's asymmetry means the fan version is not sufficient.

| Trigger | Handled by | Added for charging |
|---|---|---|
| User asks | `clientAskedForFirmware` | — |
| App quits / crashes | `clientDisconnected` (XPC invalidation) | — |
| App wedged but connected | `heartbeatExpired`, 15 s | — |
| Daemon `SIGTERM`/`SIGINT`/`SIGHUP` | dispatch signal sources + `atexit` in `main.swift` | — |
| Daemon idle, app deleted | `idleWithNoClient` → revert, then exit, 60 s | — |
| **Daemon `SIGKILL`ed** | **Nothing — no handler runs** | **Release-on-start** |
| **Reboot with a stale gate** | **Nothing** | **Release-on-start — but see the gap** |
| **Wake from sleep / hibernation** | — | **Re-read state and reconcile; never assume the gate survived** |
| **SoC below the emergency floor** | — | **Deadman check on the existing 1 s tick** |
| **Charging observed still running after a write** | — | **Readback → `verifiedApplied == false`** |

Four additions:

1. **Release-on-start, unconditionally.** Before `listener.resume()`, in the slot
   `service.probeHardware()` occupies in `main.swift`, clear any charge gate the
   daemon can see — whether or not it believes it set one. The only recovery
   from a `SIGKILL`ed or crashed predecessor.
2. **A deadman floor on the existing 1 s tick.** `FanDaemonFailSafe.dueTrigger`
   gains a case for "observed SoC below the emergency floor", which releases the
   ceiling even while the client is healthy and heartbeating. The client cannot
   suppress it and there is no protocol method to disable it.
3. **Wake reconciliation.** §4.2 item 3: imperative gates persist through sleep
   as last written, and firmware resets keys after hibernation. Neither
   "it survived" nor "it was cleared" may be assumed; the daemon re-reads and
   reconciles on wake, and reports the result rather than silently re-asserting.
4. **A boot-time clear — and the honest gap.** The daemon's plist deliberately
   omits `RunAtLoad` and `KeepAlive`, and that omission is load-bearing:
   "A daemon that cannot stay dead cannot be the mitigation for a leaked
   daemon." But release-on-start only runs when something *starts* the daemon,
   and after a reboot with the app uninstalled, nothing does.

   The mitigating fact is real: on Apple Silicon a reboot **is** an SMC reset,
   so imperative gates do not survive one (§4.2 item 2). The unmitigated case is
   a **firmware-enforced** limit (`CHLS`/`bf*`), which by design does survive —
   and that is the class Apple is moving to. **If the implementation ever writes
   a firmware-enforced limit, there is a state this design cannot clean up**,
   and adding `RunAtLoad` to fix it would break the leaked-daemon mitigation the
   current plist was written for.

   That tension is unresolved here on purpose, and it is a **gate**: it must be
   settled by measuring which class the chosen key falls into (§7) before a line
   of this is written. If the answer is "firmware-enforced", this design is not
   shippable as drafted.

### 6.5 Uninstall

`FanDaemonFailSafe`'s uninstall note applies unchanged and gets worse in
proportion to the stakes: a drag-to-Trash uninstall never calls
`SMAppService.unregister()`, a running copy keeps running as root, and the
residue is a launchd job record pointing at a missing binary. For fans the
mitigation chain (`clientDisconnected` → revert, `idleWithNoClient` → exit) is
adequate. For charging it is adequate **only if the revert write succeeds** —
and a failed revert write currently produces a log line. Here it must also
produce a user-visible, persistent, escalating warning, because the failure is
silent at the hardware and the user's first symptom is a flat battery. This is
not hypothetical: it is the single most-reported catastrophic outcome in §2.4
item 4, across years of AlDente issues.

---

## 7. Open questions

Flagged rather than guessed. Each would change a recommendation if answered
differently.

1. **Is `CHWA` absent because of the M4 generation, or because macOS 26.4/26.x
   removed it fleet-wide?** (§3.1.) Cheap to answer: run the read-only probe on
   an M1 or M2 Mac. The corroborating evidence favours "fleet-wide", but this is
   inference.
2. **What is `CHNC` bit 22?** This machine sets it (with bit 0, battery full, at
   100 % charge on AC). It is not in the Linux mainline list. Sentry's own code
   comment has been carrying this exact unknown. Answerable by sampling `CHNC`
   across states — hot, limited, on OBC hold, unplugged.
3. **Is `CHLS` the mechanism behind macOS 26.4's limit?** Three facts converge —
   `CHLS`'s fixed −5 start offset matches Apple's "resumes if it drops more than
   5 %" rule, Linux defines `CHNC_CHLS_LIMIT = BIT(24)`, and OpenDente reads bit
   24 specifically to detect the native limit — but I found no source stating it
   outright. **Likely, not verified.**
4. **Which Apple Silicon Macs get the 26.4 Charge Limit?** Apple's requirement
   line says only "a Mac with Apple silicon"; no model enumeration exists that I
   could find, and I could not retrieve the body of `support.apple.com/102338`.
   Sentry's UI must not claim a floor it has not confirmed. Related:
   `DeviceSupports80ChargeLimit` is the gate name, but its value is not exposed
   in `ioreg` and I could not find where it is read from.
5. **Does a firmware-enforced limit survive shutdown?** §6.4's gate. Unverified
   for `CHLS`/`bf*`, and it decides whether §6 is shippable at all.
6. **Can Sentry read the current OS charge limit?** No read intent exists
   (§3.4). `CHNC` bit 24 answers "a limit is holding right now" but not "the
   limit is set to 85 %". `/Library/Preferences/com.apple.powerd.charging.plist`
   holds an `NSKeyedArchiver` `policies` array (empty here, with no limit set) —
   a private format, plausible but not a foundation. **One cheap experiment
   settles this:** set a limit in System Settings, then re-read that file,
   `CHNC`, and `NotChargingReason`.
7. **Does `shortcuts://run-shortcut` drive the App Intent without stealing
   focus?** Sentry's existing `runShortcut` path was built for user-initiated
   alert actions, not silent background writes. `/usr/bin/shortcuts run` may be
   the better transport. Untested for this use.
8. **`bfD0`/`bfE0`/`bfF0`** (the `20xxx`-firmware limit family) rest on a
   **single source**, `charlie0129/batt`. Not independently confirmed.
9. **Why was `Battery-Toolkit` archived?** No maintainer statement found. The
   timing — 21 March 2026, three days before macOS 26.4 shipped the native
   limit — is suggestive. Not asserting causation.

---

## 8. Method note

Everything in §3.1–§3.4 was measured on the probe machine on 2026-08-07:

- Read-only SMC enumeration and key inspection (commands 8, 9, 5 only; **no
  `WRITE_BYTES`**), written for this document and kept out of the repo — the
  same convention `docs/fan-control-spike.md` used for the fan probe.
- `ioreg -rn AppleSmartBattery`, `pmset`, `codesign -d --entitlements -`, and
  `strings` over `powerd`, `PowerUIAgent` and `PowerPreferences.appex`.
- App Intents metadata from
  `ActionKit.framework/…/Metadata.appintents/extract.actionsdata`.

Third-party key semantics in §3.1 come from `mhaeuser/Battery-Toolkit`,
`charlie0129/batt`, `actuallymentor/battery`, `zackelia/bclm`, and the Linux
mainline `drivers/power/supply/macsmc-power.c` (the most authoritative of the
five, being a reviewed kernel driver).

**No SMC key was written and no system setting was changed in the course of
this research.**
