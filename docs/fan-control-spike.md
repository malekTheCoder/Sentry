# Fan Control — Phase 1 research spike findings

Date: 2026-08-01 · Hardware: MacBookPro18,3 (14" M1 Pro, 2 fans)

This answers the plan's Phase 1 gates (privilege requirements, hardware
support, failure modes) with measurements from real hardware, not
documentation folklore. Probe source: read-only SMC key reader (selector 2,
80-byte `SMCParamStruct`), kept out of the repo; the shipping implementation
it validated is `SystemMetricsKit/Bridges/SMCFanBridge.swift`.

**⚠️ Single-hardware caveat.** Every measurement in this document — the key
names, the type codes, the attribute bits, the ranges — comes from one
machine, the M1 Pro above. Nothing here has been checked against an M2, M3,
or M4 Mac. Apple has changed SMC key layouts across generations before, so
treating these findings as "how the SMC works on Apple Silicon" rather than
"how it works on this specific Mac" would be overclaiming. **Per-generation
SMC key validation (M2/M3/M4) is an open item, not attempted here or as
part of the readback-verification fix below** — that fix builds on top of
the keys this document already measured (`F{i}Tg`, `F{i}Ac`) and does not
widen the hardware this has been checked against.

## Findings

| Question | Answer (measured) |
|---|---|
| Does the classic `AppleSMC` user client exist on Apple Silicon? | Yes — `AppleSMC` service with `AppleSMCKeysEndpoint`; `IOServiceOpen` succeeds **unprivileged**. |
| Are fan keys present? | Yes. `FNum` = 2; per-fan `F{i}Ac` (actual), `F{i}Tg` (target), `F{i}Mn`/`F{i}Mx` (limits), `F{i}Md` (mode), all type `flt `/`ui8 `. |
| Measured ranges | Fan 0: 1200–5779 RPM. Fan 1: 1200–6241 RPM. Actual/target read 0.0 at idle — Apple Silicon parks its fans; 0 is a *real* reading. |
| Privileges for **reading** | None. Everything above read as a normal user. |
| Privileges for **writing** | `F0Tg`/`F0Md` carry the writable attribute bit (attr `0xd4`/`0xd0`), but SMC key writes require root on Apple Silicon → a privileged helper (`SMAppService` LaunchDaemon). Not attempted in the spike (read-only by design). |
| Fanless hardware (MacBook Air) | `FNum` absent/unreadable → capability detection = "no fan keys", exactly the unsupported state the plan requires. |

## Consequences for the plan

1. **The plan's MVP item 1 (fan RPM readout) did not exist yet** — 
   `HIDSensorBridge.readFanRPMs()` was a deliberate stub because the HID
   fan field selector is unknowable. The SMC key path replaces it and is
   now implemented and wired into `ThermalCollector` (read-only).
2. **MVP items 1–2 (readout + capability detection) need no privileges and
   no helper.** Shipped now.
3. **Everything from "manual override" onward needs the root helper.** With
   the app currently ad-hoc signed, `SMAppService` daemon registration is
   the fragile part — that, not the SMC protocol, is the real Phase 3 risk.
4. Readback verification is straightforward: write `F{i}Tg`, poll `F{i}Ac`.
   **Implemented** — `SMCFanWriter.setTargetRPM` now polls `F{i}Ac` a few
   times across roughly a second after the write and reports two distinct
   booleans, `accepted` (the SMC took the write) and `applied` (the fan's
   actual RPM was observed moving toward the target), up through
   `FanDaemonProtocol.setTarget` and `FanControlBackend.applyTarget`. See
   "Readback verification" below. Revert-to-auto is `F{i}Md = 0`. Clamps
   come from the SMC's own `F{i}Mn`/`F{i}Mx`, not hardcoded numbers.
5. Path corrections to the plan's §11: paths are repo-relative
   (`SystemMetricsKit/…`, `Sentry/…`, `SentryKit/…`), not nested under a
   `Sentry/` prefix.

## Status

- [x] Phase 1: research spike (this document)
- [x] Fan RPM readout via `SMCFanBridge` (read-only), surfaced in the
      existing Dashboard thermal card ("Fan 1 / Fan 2" rows)
- [x] Phase 2: read-only control shell — model types (`SentryKit/Models/
      FanControl.swift`), persisted policy block (`AppSettings.fanControl`),
      the write seam (`SentryKit/Services/FanControlBackend.swift`), the
      read-only real backend (`SystemMetricsKit/Bridges/
      SMCReadOnlyFanControlBackend.swift`), and Settings ▸ Fans
      (`Sentry/Settings/Panes/FanControlPane.swift`). Live RPM is real;
      **every control that would require a write is disabled and says why on
      screen.** No curve editor, no "Return to Auto" button, no dropdown
      surface — all three would be dead controls today, and the rationale
      for each omission is recorded in `FanControlPane`'s doc comment.
- [x] Phase 3: the write path — a privileged helper. Built. `SentryFanDaemon`
      (a `tool` target, four files of its own plus the six files in
      `SentryKit/FanDaemon/`), registered by `SMAppService.daemon(plistName:)`
      from `PrivilegedFanControlBackend` **only when the user presses Install
      in Settings ▸ Fans**. `FanWriteAvailability` gained the `.available`
      case the Phase 2 note promised would break every `switch` over it; each
      one was revisited in the same change.
- [x] Readback verification (item 4 above) — a write is no longer reported
      as successful purely because the SMC accepted `WRITE_BYTES`. See
      "Readback verification" below.

## Phase 3: what was built, and what is unverified

### Architecture, in one paragraph

`Sentry.app` contains no code that can write an SMC key — `SMCFanBridge`
still emits only `READ_KEYINFO` and `READ_BYTES`, and that claim is
verifiable by grep. The write command byte lives in one file
(`SentryFanDaemon/SMCFanWriter.swift`) in a separate root binary. The app
reaches it through four XPC methods (`heartbeat`, `describe`, `setTarget`,
`returnToFirmware`) and no method carries an SMC key name or a byte payload,
so a fully-compromised client still cannot address an arbitrary register.
The daemon re-clamps every request against its own `F{i}Mn`/`F{i}Mx` read,
performed in its own process at start, and **refuses rather than passing
through** when a fan's range is unreadable. Peer verification is
`SMAuthorizedClients` (enforced by launchd, embedded in the daemon binary's
`__info_plist` section) plus `FanDaemonPeerGate` inside the daemon, both
pinning bundle id + `anchor apple generic` + Team ID `H7T2D2GL7U`.

### Fail-safe, and the app-side watchdog being the weaker half

Fans return to `F{i}Md = 0` on: client disconnect, client crash
(`interruptionHandler`), heartbeat silence ≥ 15 s, `SIGTERM`/`SIGINT`/`SIGHUP`
(via dispatch sources, so the handler may allocate and call IOKit),
`atexit`, and an explicit Return to Auto. With no client at all the daemon
reverts and **exits** after 60 s. The app also asks on quit — that is a
courtesy, not the guarantee, exactly as `PowerControlService` documents for
`IOPMAssertion`s. `SIGKILL` runs nothing; what bounds that is the SMC's own
`F{i}Mn` floor (a stuck override cannot park a fan below what the firmware
itself considers safe) and the fact that `F{i}Md` does not survive a power
cycle.

### Readback verification

Item 4 above named the fix and, for a while, nothing implemented it:
`SMCFanWriter.setTargetRPM` reported success purely from `WRITE_BYTES`
being accepted, never from the fan actually moving. That gap is exactly
market research's top complaint about four of seven competitor apps
(Stats, TG Pro, Sensei, iStatistica): `thermalmonitord` can re-assert
protected mode and silently override an accepted write, and an app that
only checks acceptance tells the user it worked anyway.

The fix: after `F{i}Tg` is written, `setTargetRPM` polls `F{i}Ac` (four
samples, ~350 ms apart, so roughly a second of polling — long enough for a
fan to visibly start responding, short enough not to block the synchronous
XPC call for long) and returns a `FanWriteVerification` with two
independent booleans:

* `accepted` — the SMC took the write. This is all the pre-fix code
  checked.
* `applied` — the fan's actual RPM was seen landing within a tolerance
  band of the target, or moving meaningfully toward it (`FanDaemonReadback
  .applied`, in `SentryKit/FanDaemon/FanDaemonReadback.swift` — a pure,
  unit-tested function over the samples, separate from the SMC I/O that
  cannot be unit-tested on a machine with no signing identities).

`accepted && !applied` is the "SMC said yes, thermalmonitord said no"
case. It is threaded up as its own thing at every layer rather than folded
into an ordinary failure: `FanDaemonService.setTarget` logs it at fault
level (distinct from the `.notice` a verified success gets) and replies
with `verifiedApplied: false` and no failure message (the SMC did not
refuse anything, so `FanDaemonRefusal` doesn't apply);
`FanDaemonProtocol.setTarget` carries `verifiedApplied` as a fourth reply
parameter; `PrivilegedFanControlBackend.applyTarget` throws the new
`FanControlWriteError.writeNotVerified(requestedRPM:fanIndex:)` rather than
treating it as `.helperRefused` or as success. The fan stays held (`F{i}Md`
remains 1) in the unverified case exactly as it does in the verified one —
an unconfirmed write is a reason to say so, not a reason to hand the fan
back to firmware control out from under a client that still believes it is
holding it.

**Caveat, stated the same way the rest of this document does.** The
tolerance band (150 rpm) and movement threshold (75 rpm) that decide
`applied` are reasoned from the ranges this document measured and from
Apple Silicon's observed idle-to-ramp behavior, not tuned against an
observed `thermalmonitord` override — because, per the single-hardware
caveat above and the section below, the write path itself has never run.
Revisit both constants against real hardware in the first-run checklist.

### Uninstall, stated without softening

`SMAppService.unregister()` is reached only from the **Remove fan helper**
button in Settings ▸ Fans. A drag-to-Trash uninstall never reaches it. What
then happens, precisely:

* launchd keeps the job registered, but its `BundleProgram` path no longer
  exists, so the daemon **cannot be started again**.
* A copy that happened to be running at the moment of deletion keeps running
  as root — until its client disconnects (reverting every held fan) and the
  60-second idle window elapses, at which point it exits by itself. That
  window is the mitigation, and it is bounded, not zero.
* A **Login Items & Extensions entry can remain**, attributed to Sentry.
  This branch does not remove it and does not claim to. The user can switch
  it off there, or run:

      sudo launchctl bootout system/dev.malekswilam.sentry.fandaemon

The Fans pane says all of this on screen, before the Install button, in the
section footer — not only here.

### ⚠️ What has never been observed, and could not be from this branch

This machine has **zero code-signing identities** (`security find-identity -v
-p codesigning` → "0 valid identities found"). `SMAppService.daemon`
registration requires the daemon signed with the same real Team ID as the app
plus a satisfied `SMAuthorizedClients` requirement, so registration fails
here by construction and the Mach service is never published. Therefore
**none of the following has ever run**:

1. A successful `SMAppService.register()`.
2. Any XPC connection between the app and the daemon — so no `heartbeat`,
   `describe`, `setTarget`, or `returnToFirmware` round trip.
3. `SecCodeCheckValidity` returning `errSecSuccess` against a real signed
   Sentry. Only the *decision logic* around it (`FanDaemonPeerGate`) is
   tested, with a fake evaluator.
4. **Any SMC write.** `WRITE_BYTES` (command 6) against `F{i}Tg`/`F{i}Md` has
   never been executed. The byte layout is the read layout the spike verified,
   with the command byte changed and the payload written into the same
   offset the reader decodes from — a strong inference, not a measurement.
5. launchd's behavior on daemon exit, and whether it respects the omitted
   `KeepAlive` the way this design needs it to.
6. **The readback-verification poll actually catching a `thermalmonitord`
   override.** `FanDaemonReadback.applied`'s tolerance band and movement
   threshold are unit-tested against fabricated sample sequences (see
   "Readback verification" above and `SentryTests/FanDaemonReadbackTests
   .swift`), which proves the *arithmetic* is correct. It does not prove
   the constants are well-tuned against a real override, because no write
   has run to produce one.

What *has* been verified, on this hardware, from this branch: the app with no
registered daemon behaves exactly as it did in Phase 2 — two fans detected,
live RPM (2327 / 2477 rpm, range 2317–7826), every write control disabled,
`needsPrivilegedHelper` explained on screen, no crash, no hang, no admin
prompt, and no log line from `PrivilegedFanControlBackend` (it never
attempted a connection).

### First-run checklist once real certificates exist

Do these **in order**, on a machine you are willing to reboot:

1. Archive with a real `Developer ID Application` identity for team
   `H7T2D2GL7U`. Confirm the daemon is signed and carries the requirement:
   `codesign -dv --entitlements - Sentry.app/Contents/MacOS/SentryFanDaemon`
   and `otool -X -s __TEXT __info_plist …` should show `SMAuthorizedClients`.
2. Confirm the plist landed: `ls Sentry.app/Contents/Library/LaunchDaemons/`.
3. Launch, open Settings ▸ Fans, confirm it still reads inert **before**
   installing.
4. Press Install. Expect an authorization prompt and, most likely,
   `.requiresApproval` — approve in System Settings ▸ General ▸ Login Items &
   Extensions, then return to the pane (it re-reads on appearance).
5. `sudo launchctl print system/dev.malekswilam.sentry.fandaemon` — confirm
   the job exists and the Mach service is registered.
6. **Watch the fans and the log while applying a fixed speed.** `log stream
   --predicate 'subsystem == "dev.malekswilam.sentry.fandaemon"'`. Verify
   the applied RPM matches what the daemon reports, that a deliberately
   out-of-range request (e.g. 12000) comes back clamped and *says* it was,
   and that a verified write logs at `.notice` while `verifiedApplied` reads
   `true` in the app. If a request comes back `accepted` but not
   `verifiedApplied` on hardware that should have complied, that is the
   signal to re-tune `FanDaemonReadback`'s tolerance band and movement
   threshold against what real fan ramp behavior actually looks like.
7. **Verify the fail-safe before trusting it.** With a fan held: `kill` the
   app (not the daemon) and confirm the fans return to firmware control
   within a second or two; then wedge the app (attach a debugger and pause
   it) and confirm the 15-second heartbeat expiry fires.
8. Confirm the daemon exits on its own ~60 s after the app quits.
9. Only then consider whether the sensor-curve control loop
   (`FanControlService`'s documented omission) is worth building.
