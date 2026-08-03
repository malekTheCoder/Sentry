# Fan Control — Phase 1 research spike findings

Date: 2026-08-01 · Hardware: MacBookPro18,3 (14" M1 Pro, 2 fans)

This answers the plan's Phase 1 gates (privilege requirements, hardware
support, failure modes) with measurements from real hardware, not
documentation folklore. Probe source: read-only SMC key reader (selector 2,
80-byte `SMCParamStruct`), kept out of the repo; the shipping implementation
it validated is `SystemMetricsKit/Bridges/SMCFanBridge.swift`.

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
   Revert-to-auto is `F{i}Md = 0`. Clamps come from the SMC's own
   `F{i}Mn`/`F{i}Mx`, not hardcoded numbers.
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
      (a `tool` target, four files of its own plus the four pure files in
      `SentryKit/FanDaemon/`), registered by `SMAppService.daemon(plistName:)`
      from `PrivilegedFanControlBackend` **only when the user presses Install
      in Settings ▸ Fans**. `FanWriteAvailability` gained the `.available`
      case the Phase 2 note promised would break every `switch` over it; each
      one was revisited in the same change.

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
   the applied RPM matches what the daemon reports, and that a deliberately
   out-of-range request (e.g. 12000) comes back clamped and *says* it was.
7. **Verify the fail-safe before trusting it.** With a fan held: `kill` the
   app (not the daemon) and confirm the fans return to firmware control
   within a second or two; then wedge the app (attach a debugger and pause
   it) and confirm the 15-second heartbeat expiry fires.
8. Confirm the daemon exits on its own ~60 s after the app quits.
9. Only then consider whether the sensor-curve control loop
   (`FanControlService`'s documented omission) is worth building.
