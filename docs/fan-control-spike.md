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
   (`SystemMetricsKit/…`, `MacStat/…`, `MacStatKit/…`), not nested under a
   `MacStat/` prefix.

## Status

- [x] Phase 1: research spike (this document)
- [x] Fan RPM readout via `SMCFanBridge` (read-only), surfaced in the
      existing Dashboard thermal card ("Fan 1 / Fan 2" rows)
- [x] Phase 2: read-only control shell — model types (`MacStatKit/Models/
      FanControl.swift`), persisted policy block (`AppSettings.fanControl`),
      the write seam (`MacStatKit/Services/FanControlBackend.swift`), the
      read-only real backend (`SystemMetricsKit/Bridges/
      SMCReadOnlyFanControlBackend.swift`), and Settings ▸ Fans
      (`MacStat/Settings/Panes/FanControlPane.swift`). Live RPM is real;
      **every control that would require a write is disabled and says why on
      screen.** No curve editor, no "Return to Auto" button, no dropdown
      surface — all three would be dead controls today, and the rationale
      for each omission is recorded in `FanControlPane`'s doc comment.
- [ ] Phase 3: the write path — a privileged helper. **Not started; still
      needs an explicit decision on shipping a root helper**, and note the
      finding above: `SMAppService` daemon registration under this project's
      ad-hoc signing is the real risk, not the SMC protocol. There is
      deliberately no `FanWriteAvailability` case meaning "writes work", so
      Phase 3 cannot half-land: adding one breaks every `switch` over it,
      including the Settings pane's disabled-control copy.
