# STATUS — what is left before Sentry ships

**Read this first.** Reconciled **2026-09-10** against `main` at `661d2e0`.
This page is the single list of open work; the four checklists it
summarises (`appstore-review-readiness.md`, `release-checklist.md`,
`asc-metadata-draft.md`) keep the detail
and the per-item evidence. Every "done" below was verified on that date by
reading the source at the quoted file and line, or by a live `curl -L`
from this machine — not inferred from a commit message. If you find a
claim here that no longer matches the tree, fix this file in the same
change that made it wrong.

> **2026-09-15 — Sentry Pro is cancelled.** The product owner's decision:
> Sentry becomes free and open source, with no payment of any kind. Every
> formerly-gated feature is now unconditionally available and the whole
> licensing apparatus has been **deleted**, not disabled —
> `SentryKit/Pro/` (licence format, verification, entitlement store,
> revalidation scheduler), `ProGate`, `HistoryProGate`,
> `ThemeEditingGate`, `ProPurchase`, the upsell cards, the locked rows,
> Settings ▸ Sentry Pro, and the three `AppSettings` licence fields. The
> two checklists that described the checkout
> (`pro-license-dryrun-checklist.md`, `privacy-policy-checkout-draft.md`)
> are deleted with it. **Nothing below is "waiting on a payment vendor"
> any more; those items are cancelled, not pending**, and are recorded as
> such so nobody re-opens them. What remains blocked is the release
> machinery — certificates, notarization, App Store Connect — which never
> depended on Pro.

## Already done — do not redo

| What | Proof |
|---|---|
| Privacy policy live | `https://malekthecoder.github.io/Sentry/privacy-policy` → 200; effective date and `getsentryapp@gmail.com` on the page (`gh-pages` `4deba60`) |
| Sparkle appcast live | `…/Sentry/appcast.xml` → 200, well-formed, deliberately empty channel (`gh-pages` `ffe7e7c`) |
| Support page live | `…/Sentry/support` → 200; GitHub Issues + support email |
| Marketing site live | `https://malekswilam.dev/SentryWebsite/` → 200 |
| Sparkle EdDSA public key embedded | `project.yml:637`, real key, generated 2026-08-13 (`b513558`) |
| Developer ID Application cert | present on **Aniketh's** machine (2026-09-10). **Not on Malek's** — `security find-identity -v -p codesigning` there reports 0 valid identities (checked 2026-09-12). See Human 2a. |
| Every iOS review-readiness code fix | demo device renamed, demo banner on all four tabs, all three widget families tagged, honest mock keep-awake feedback, Mac-app download link, `protectionScore` hook, "this build" copy removed (`2dd538a`, `2ad7549`, `74cafb9`, `7d9eb18`) |
| iOS/watchOS version strings | all four bundles substitute `1.0.0`/`2` from `project.yml:84–85` |
| Export-compliance answer | `ITSAppUsesNonExemptEncryption: false` in the iOS plist (`c50f8b2`) |
| All ASC copy drafted | `asc-metadata-draft.md`: name, subtitle, description, keywords, promo text, URLs, age rating, privacy answers, review notes, video shot list |
| ASC screenshot pipeline | `scripts/asc-screenshots.sh` — iPhone 6.9" (1320×2868, iPhone 17 Pro Max) and Watch (422×514, Ultra 3) at Apple's exact sizes, demo data disclosed on-screen, driven by `SentryMobileUITests`/`SentryWatchUITests`; run end to end 2026-09-10 |
| Watch audit 2026-09-10 (branch `audit/watch-final`) | Four checks, each read against the source. (1) Live/stale/never-paired: Overview and Agent pages and all four complication families already used `Freshness`; `KeepAwakePage` had no staleness cue at all (its header claimed the shell drew one — it never did) and the Agent page's "Out of date" was computed once per relay — both now re-derive on `FreshnessBadge.defaultRefreshInterval`, Keep Awake shows `FreshnessPill` past `warrantsCompactStalenessCue`. `WatchGetBatteryStatusIntent` spoke "battery is at 0%" for a desktop Mac — now guarded by `showsBattery`. (2) Keep-awake: indefinite holds from any surface render correctly (`awakeIsActive`/`awakeExpiresAt` flattened from the two-slot union `PowerControlService.state`); a *timed* hold past its deadline still said "Keeping awake" with live extend buttons, and a deadline elapsing on screen counted up — now a `TimelineView` boundary standing down the present-tense chrome, same wording as the phone's `SleepStatusCard`. (3) Themes: `Theme.builtInPresets` is System/Ivory/One Dark; new `WatchThemeColors` (`SentryKit/Watch/`) + `WatchControlContrastTests` sweep every preset × appearance × control on the bytes drawn. Found and fixed: System's translucent light `background` composited over the black watch window (grey canvas, not the phone's white), and control labels under 3:1 on their own wash (System light success 1.8:1). (4) Complication: `sourceIsDemoData` disclosed in `.accessoryRectangular`, the only family with room — parity with the phone's accessory families; the three phone home-screen families remain the standard for families with room. macOS suite after: 1687 + 10 new = 1697 tests, 6 failures (the pre-existing °F six); watchOS simulator build green; every Keep Awake state screenshotted on the Series 11 46mm sim via the `-SentryWatchPage` launch argument. |
| Sentry Pro removed in full | `feat/free-and-open`: `SentryKit/Pro/`, `ProGate`, `HistoryProGate`, `ThemeEditingGate`, `ProPurchase`, `ProUpsellCard`, `ProLicensePane`, `ProLicenseActivationModel` and their seven test files deleted; all six formerly-gated features unconditionally available; `AppSettings` lost `proUnlockOverrideEnabled`/`proLicenseBlob`/`proLicenseLastVerifiedAt` with `AppSettingsProRemovalTests` proving a licensed install's `settings.json` still decodes; `AppCredits.copyright` corrected from "All rights reserved" to the MIT grant this repo actually publishes under. macOS suite 1629 tests, 0 failures; iOS simulator build green |

## 1. Human-only

Nothing an agent can do. Numbered as in the launch plan.

1. ~~Developer ID Application certificate for team `H7T2D2GL7U`.~~ **Exists on Aniketh's machine** (2026-09-10). Not yet exercised by a full `scripts/release.sh` run — see Blocked.
2a. **Get the certificate and the Sparkle private key onto the same machine.** This is the real blocker behind every release item and it is easy to miss, because each half looks done on its own. The Developer ID certificate is on Aniketh's Mac; the Sparkle EdDSA private key — the one that signs the appcast, generated 2026-08-13 — is in Malek's login keychain and nowhere else. `scripts/release.sh` needs **both at once**: it archives and notarizes with the certificate, then signs the appcast entry with the Sparkle key, in one run. Whoever cuts releases needs both halves; decide who that is and move the other half to them (export the certificate as a `.p12`, or export the Sparkle key with `generate_keys -x`), over something private.
2. **Store the notarization credential**: `xcrun notarytool store-credentials AC_NOTARY …` (exact invocation in the `scripts/release.sh` header). Verified absent 2026-09-10 — `notarytool history --keychain-profile AC_NOTARY` reports no keychain item. Needs the App Store Connect app-specific password.
3. ~~**Pick a payment vendor**, open the merchant account, decide the price.~~ **Cancelled 2026-09-15** — Sentry is free. There is no vendor to pick, no merchant account to open, and no price. Do not reopen.
4. ~~**Generate the production Pro-licence Ed25519 keypair.**~~ **Cancelled 2026-09-15** — `LicenseKeys` and the whole `SentryKit/Pro/` directory are deleted; there is nothing for a keypair to sign. (Unrelated to the *Sparkle* EdDSA key in item 10, which is live and still matters.)
5. **App Store Connect data entry** from `asc-metadata-draft.md` — every field is paste-ready. Includes the privacy-policy URL, App Privacy ("No" to the gate question), age rating (all None/No), category, screenshots (iPhone 6.9" and Watch — generated at the exact required pixel sizes by `scripts/asc-screenshots.sh`; upload from `build/asc-screenshots/`), review notes, and confirming bundle ID / App Group / provisioning profiles for all four bundles.
6. **EU Digital Services Act trader-status verification** with Apple. Not started; takes time — start before submission, not at it.
7. **Decide the app name.** "Sentry" is provisional pending a trademark decision; it collides with Sentry.io. The Sparkle feed URL is now frozen (published), but the *product* name can still change as long as the GitHub account/repo path stays.
8. **Record the App Review demo video** per the shot list in `asc-metadata-draft.md` (~80 s; shot 4 — a real keep-awake round trip — is the load-bearing one).
9. **Decide what to do about the public `v1.0` GitHub release.** Tag `cb0e992` (2026-08-09; release published 2026-08-08 with `Sentry.dmg`) predates the real Sparkle key (`b513558`, 2026-08-13), so those binaries hold the placeholder `SUPublicEDKey` and can never auto-update. Options: leave it, post a re-download notice, or cut a `v1.0.x` that `releases/latest` picks up.
10. **Back up the Sparkle private key offline** (`generate_keys -x`; procedure in `project.yml` above line 637). Cannot be verified from the repo; losing it orphans every install with no recovery.
11. **Capture the keep-awake Live Activity screenshot by hand**, if it is wanted in the listing. `scripts/asc-screenshots.sh` cannot: `KeepAwakeActivityController.observeSnapshots` (`SentryMobile/LiveActivity/KeepAwakeActivityController.swift:156`) refuses to start an activity from demo data by design, so the Dynamic Island / Lock Screen presentation only exists with a real Mac running Sentry, holding a keep-awake, and the simulator app connected to it (launched *without* `-SentryDemoData`). Recipe in the script's header. Optional — ASC does not require it.

## 2. Blocked — agent-doable, waiting on something above

| Work | Waiting on |
|---|---|
| Run `scripts/release.sh` end to end (archive → export → verify → DMG → notarize → staple → appcast) and confirm the `spctl -a -vvv -t install` Gatekeeper assessment | Human 2 (notary credential) |
| Verify the SMAppService / command-line-bridge flow under a Developer ID signature (only run under ad-hoc / Apple Development so far) | the first Developer ID build above |
| Cut the first notarized release: tag `vX.Y.Z`, GitHub release with `Sentry.dmg` (must keep exactly that asset name — the README links `releases/latest/download/Sentry.dmg`) and SHA-256, publish the signed appcast entry | Human 2, Human 9 |
| Any App Store Connect work beyond drafting | Human 5, Human 7 (the record should not be created before the name is settled) |

**Six payment items used to sit in this table** — writing the
`LicenseActivationClient` conformer, pasting a checkout URL into
`AppCredits`, building the licence-issuance backend, flipping the
composition root to a `.standard` revalidation policy, walking the Pro dry
run, and revising the privacy policy for checkout. **All six are cancelled,
not pending.** The code each described is deleted, the two checklists they
pointed at are deleted, and the privacy policy needs no checkout revision
because there is no checkout: the published policy already describes an app
that collects nothing, and that is now the whole truth rather than the
pre-launch half of it.

## 3. Ready for an agent right now

**All five items in this section were closed on 2026-09-12.** Kept below with
their resolution rather than deleted, so the next person can see what was done
and check it rather than re-deriving it.

- ~~Sync the privacy policy copies on `main` with the published one.~~ **Done —
  and the drift ran the other way too, which mattered more.** The `gh-pages`
  copy had the load-bearing `permalink:` front matter that `main` lacked, but
  `main` had the *newer text*: the published policy still described "Location
  Log" as a live feature that "records where the Mac was last seen" and streams
  "its coordinates" over the LAN. Location was removed from the app before
  release — `grep -rl "CLLocationManager\|import CoreLocation"` across every
  target returns nothing, and `project.yml` carries no `NSLocation*` usage
  string by design. So the live legal document was claiming the app collects a
  category of data it cannot collect, while `asc-metadata-draft.md` answers
  App Privacy with **Data Not Collected** — a reviewer comparing the two would
  have found them contradicting each other. `main`'s copy now carries both the
  front matter and the corrected text, and `gh-pages` has been republished from
  it.
- ~~Stale doc comment at `SentryMobile/Intents/SentryIntents.swift`.~~ **Done.**
  It described the Mac-side `protectionScore` hook as unassigned; it is assigned
  at `Sentry/App/AppDelegate.swift:315` (`onScoreComputed`). Rewritten to
  describe what is true now, keeping the honest-`nil` explanation for a Mac
  whose Insights tab has never computed a report.
- ~~macOS widget appex version strings.~~ **Done, and the underlying cause was
  worse than the symptom.** Adding the two substitutions fixed `1.0` → `1.0.0`,
  but then exposed a second mismatch: the app built as `1.0.0 (3)` and the appex
  as `1.0.0 (2)`. The project-wide `CURRENT_PROJECT_VERSION` was `2` while the
  `Sentry` target overrode it to `3` — an override the surrounding comment
  justified as harmless "identical values", which had silently stopped being
  identical. The override is deleted and the base raised to `3`, so there is one
  definition again. Verified on built artifacts, not on the config: `Sentry.app`
  and its embedded `SentryWidget.appex` both report `1.0.0 (3)`, and all four
  App Store bundles (iPhone app, its widget, the Watch app, its widget) report
  `1.0.0 (3)`.
- ~~Six environment-dependent test failures.~~ **Done, and proven.** The three
  files asserted whole sentences containing `°C` while the value came from the
  process-global `TemperatureUnit.display`, which `SettingsStore.mirrorTemperatureUnit()`
  writes from whichever `~/Library/Application Support/Sentry/settings.json` the
  developer happens to have — so the suite's result depended on a file outside
  the repository. They now save, pin to `.celsius`, and restore, the discipline
  `TemperatureUnitTests` already documents. Proven load-bearing rather than
  assumed: with the real settings temporarily flipped to Fahrenheit, the suite
  fails 4 tests without the fix and passes 1743/1743 with it. (The count is 4,
  not 6 — two of the six named here were fixed by other work in between.)
- ~~Remaining `TO-FILL(support-email)` markers.~~ **Done.** Both surviving
  files (`docs/privacy-policy.md`, `docs/pages-site/privacy-policy.md`) carry
  `getsentryapp@gmail.com` as a `mailto:` link. A third,
  `docs/privacy-policy-checkout-draft.md`, was fixed at the same time and has
  since been deleted with the rest of the checkout work. The only remaining
  occurrences of the string in the tree are inside this file and
  `release-checklist.md`, where they describe the markers rather than being
  one.

---

*How to keep this page true:* when you close an item, move it to "Already
done" with its proof; when you discover a new one, put it in the right
bucket with a file:line. Do not add anything you have not verified.
