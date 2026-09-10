# STATUS — what is left before Sentry ships

**Read this first.** Reconciled **2026-09-10** against `main` at `661d2e0`.
This page is the single list of open work; the four checklists it
summarises (`appstore-review-readiness.md`, `release-checklist.md`,
`asc-metadata-draft.md`, `pro-license-dryrun-checklist.md`) keep the detail
and the per-item evidence. Every "done" below was verified on that date by
reading the source at the quoted file and line, or by a live `curl -L`
from this machine — not inferred from a commit message. If you find a
claim here that no longer matches the tree, fix this file in the same
change that made it wrong.

## Already done — do not redo

| What | Proof |
|---|---|
| Privacy policy live | `https://malekthecoder.github.io/Sentry/privacy-policy` → 200; effective date and `getsentryapp@gmail.com` on the page (`gh-pages` `4deba60`) |
| Sparkle appcast live | `…/Sentry/appcast.xml` → 200, well-formed, deliberately empty channel (`gh-pages` `ffe7e7c`) |
| Support page live | `…/Sentry/support` → 200; GitHub Issues + support email |
| Marketing site live | `https://malekswilam.dev/SentryWebsite/` → 200 |
| Sparkle EdDSA public key embedded | `project.yml:637`, real key, generated 2026-08-13 (`b513558`) |
| Developer ID Application cert | present on this machine (`security find-identity -v -p codesigning`, team `H7T2D2GL7U`) |
| Every iOS review-readiness code fix | demo device renamed, demo banner on all four tabs, all three widget families tagged, honest mock keep-awake feedback, Mac-app download link, `protectionScore` hook, "this build" copy removed (`2dd538a`, `2ad7549`, `74cafb9`, `7d9eb18`) |
| iOS/watchOS version strings | all four bundles substitute `1.0.0`/`2` from `project.yml:84–85` |
| Export-compliance answer | `ITSAppUsesNonExemptEncryption: false` in the iOS plist (`c50f8b2`) |
| All ASC copy drafted | `asc-metadata-draft.md`: name, subtitle, description, keywords, promo text, URLs, age rating, privacy answers, review notes, video shot list |
| Pro licence verification side | `SentryKit/Pro/` — Ed25519 blob verify, entitlement policy, install/remove/revalidate store, six gated `ProFeature`s, 659-line test file |
| Watch audit 2026-09-10 (branch `audit/watch-final`) | Four checks, each read against the source. (1) Live/stale/never-paired: Overview and Agent pages and all four complication families already used `Freshness`; `KeepAwakePage` had no staleness cue at all (its header claimed the shell drew one — it never did) and the Agent page's "Out of date" was computed once per relay — both now re-derive on `FreshnessBadge.defaultRefreshInterval`, Keep Awake shows `FreshnessPill` past `warrantsCompactStalenessCue`. `WatchGetBatteryStatusIntent` spoke "battery is at 0%" for a desktop Mac — now guarded by `showsBattery`. (2) Keep-awake: indefinite holds from any surface render correctly (`awakeIsActive`/`awakeExpiresAt` flattened from the two-slot union `PowerControlService.state`); a *timed* hold past its deadline still said "Keeping awake" with live extend buttons, and a deadline elapsing on screen counted up — now a `TimelineView` boundary standing down the present-tense chrome, same wording as the phone's `SleepStatusCard`. (3) Themes: `Theme.builtInPresets` is System/Ivory/One Dark; new `WatchThemeColors` (`SentryKit/Watch/`) + `WatchControlContrastTests` sweep every preset × appearance × control on the bytes drawn. Found and fixed: System's translucent light `background` composited over the black watch window (grey canvas, not the phone's white), and control labels under 3:1 on their own wash (System light success 1.8:1). (4) Complication: `sourceIsDemoData` disclosed in `.accessoryRectangular`, the only family with room — parity with the phone's accessory families; the three phone home-screen families remain the standard for families with room. macOS suite after: 1687 + 10 new = 1697 tests, 6 failures (the pre-existing °F six); watchOS simulator build green; every Keep Awake state screenshotted on the Series 11 46mm sim via the `-SentryWatchPage` launch argument. |
| Pro licence pane in Settings | `Sentry/Settings/Panes/ProLicensePane.swift` + `Sentry/Settings/ProLicenseActivationModel.swift`, wired via `SettingsView(licenseStore:)` from `AppDelegate`; paste/activate, denial sentences, seats/dates, Remove License; key path and "Confirm with server" render only when a client is wired. `SentryTests/ProLicenseActivationModelTests.swift` (`feat/pro-purchase-ui`) |
| Buy Sentry Pro affordance, honestly gated | `Sentry/App/ProPurchase.swift` reads `AppCredits.proCheckoutURL`, nil while `proCheckoutURLString` is the placeholder; every locked surface (Insights/Theme upsell cards, Sync locked row, Alerts locked footer, Settings ▸ Sentry Pro) renders the website's "isn't on sale yet" sentence until a real HTTPS URL is pasted. `ProPurchaseAffordanceTests`, `AppCreditsTests` |
| Revalidation scheduling wired, inert | `SentryKit/Pro/LicenseRevalidationScheduler.swift`, daily like Sparkle, started in `AppDelegate.applicationDidFinishLaunching`; `.inert` until `activationClient` and `.standard` are passed together. `LicenseRevalidationSchedulerTests` |

## 1. Human-only

Nothing an agent can do. Numbered as in the launch plan.

1. ~~Developer ID Application certificate for team `H7T2D2GL7U`.~~ **Done on this machine** (2026-09-10). Not yet exercised by a full `scripts/release.sh` run — see Blocked.
2. **Store the notarization credential**: `xcrun notarytool store-credentials AC_NOTARY …` (exact invocation in the `scripts/release.sh` header). Verified absent 2026-09-10 — `notarytool history --keychain-profile AC_NOTARY` reports no keychain item. Needs the App Store Connect app-specific password.
3. **Pick a payment vendor** (Paddle, Lemon Squeezy, …), open the merchant account, decide the price (`pro-license-dryrun-checklist.md` assumes $19.99 / $14.99 launch, 3 seats, perpetual). Not done.
4. **Generate the production Pro-licence Ed25519 keypair** offline (one-liner in `SentryKit/Pro/License.swift`'s `LicenseKeys` doc comment); store the private half in the vendor's signer and a password manager; paste the public half into `LicenseKeys.productionPublicKeyBase64` (`License.swift:258`, currently `nil`). Not done.
5. **App Store Connect data entry** from `asc-metadata-draft.md` — every field is paste-ready. Includes the privacy-policy URL, App Privacy ("No" to the gate question), age rating (all None/No), category, screenshots (iPhone 6.9" and Watch), review notes, and confirming bundle ID / App Group / provisioning profiles for all four bundles.
6. **EU Digital Services Act trader-status verification** with Apple. Not started; takes time — start before submission, not at it.
7. **Decide the app name.** "Sentry" is provisional pending a trademark decision; it collides with Sentry.io. The Sparkle feed URL is now frozen (published), but the *product* name can still change as long as the GitHub account/repo path stays.
8. **Record the App Review demo video** per the shot list in `asc-metadata-draft.md` (~80 s; shot 4 — a real keep-awake round trip — is the load-bearing one).
9. **Decide what to do about the public `v1.0` GitHub release.** Tag `cb0e992` (2026-08-09; release published 2026-08-08 with `Sentry.dmg`) predates the real Sparkle key (`b513558`, 2026-08-13), so those binaries hold the placeholder `SUPublicEDKey` and can never auto-update. Options: leave it, post a re-download notice, or cut a `v1.0.x` that `releases/latest` picks up.
10. **Back up the Sparkle private key offline** (`generate_keys -x`; procedure in `project.yml` above line 637). Cannot be verified from the repo; losing it orphans every install with no recovery.

## 2. Blocked — agent-doable, waiting on something above

| Work | Waiting on |
|---|---|
| Run `scripts/release.sh` end to end (archive → export → verify → DMG → notarize → staple → appcast) and confirm the `spctl -a -vvv -t install` Gatekeeper assessment | Human 2 (notary credential) |
| Verify the SMAppService / command-line-bridge flow under a Developer ID signature (only run under ad-hoc / Apple Development so far) | the first Developer ID build above |
| Cut the first notarized release: tag `vX.Y.Z`, GitHub release with `Sentry.dmg` (must keep exactly that asset name — the README links `releases/latest/download/Sentry.dmg`) and SHA-256, publish the signed appcast entry | Human 2, Human 9 |
| Write the concrete `LicenseActivationClient` conformer (`SentryKit/Pro/LicenseActivation.swift` is the seam; two calls, `activate` and `revalidate`). The UI that calls it is built; the exact hand-off list is "What Part 5b wires up" in `pro-license-dryrun-checklist.md` | Human 3 (vendor's API shapes) |
| Paste the vendor's HTTPS checkout URL into `AppCredits.proCheckoutURLString` (`SentryKit/Models/AppCredits.swift`) — one line; every Buy button in the app appears from it | Human 3 |
| Build the issuance backend ("task D1"): vendor webhook → verify webhook signature → mint `LicensePayload` → sign with the production key → compose `sentry-pro-v1` blob → email; idempotent on order ID; refund/chargeback → revoke | Human 3, Human 4 |
| Flip the composition root: pass the real client and `revalidationPolicy: .standard` **together** at the `LicenseProEntitlementStore(...)` call in `Sentry/App/AppDelegate.swift` (flipping the policy alone locks every licensed user out after 14 days — see `LicenseRevalidationPolicy`). The scheduler and the pane's server-facing controls arm themselves from that one edit | the client above |
| Walk the Pro dry run, steps 1–11 (`pro-license-dryrun-checklist.md`) | Human 3, Human 4, D1 |
| Revise the privacy policy for checkout (`privacy-policy-checkout-draft.md` describes a paste-only release; revalidation adds a network path and needs another revision) | the decision on whether 1.x ships revalidation |
| Any App Store Connect work beyond drafting | Human 5, Human 7 (the record should not be created before the name is settled) |

## 3. Ready for an agent right now

Everything still open that needs no human input. None of these is large.

- **Sync the privacy policy copies on `main` with the published one.** `docs/privacy-policy.md:175` and `docs/pages-site/privacy-policy.md:175` still read `TO-FILL(support-email)`; the `gh-pages` copy (`4deba60`) has `getsentryapp@gmail.com` and the load-bearing `permalink: /privacy-policy/` front matter (41 differing lines). `main` should mirror `gh-pages` so the next site edit doesn't regress the live page.
- **Stale doc comment** at `SentryMobile/Intents/SentryIntents.swift:406–416`: says the Mac-side `protectionScore` hook is "not yet assigned by the Mac composition root". It is (`Sentry/App/AppDelegate.swift:302`). Comment only; behaviour is correct.
- **macOS widget appex version strings.** `SentryWidgetExtension_macOS`'s `info:` block (`project.yml:918–967`) has no `CFBundleShortVersionString`/`CFBundleVersion` substitution, so the built `Sentry.app/Contents/PlugIns/SentryWidget.appex` reports `1.0`/`1` inside a `1.0.0`/`3` app (verified in a Debug build 2026-09-10). Not an App Store issue (Developer ID path) but the same bug class the audit fixed for iOS; align before the first notarized build.
- **Six test failures on `main` are environment-dependent.** `xcodebuild test` on 2026-09-10: 1687 tests, 6 failures, all expecting `°C` and getting `°F` (`SentryMacIntentsTests` ×2, `StatuslineRendererTests` ×3, `SystemAdvisorTests` ×1). `SettingsStore.mirrorTemperatureUnit` (`SentryKit/Settings/SettingsStore.swift:139–141`) writes the process-global `TemperatureUnit.display`, and this machine's real `~/Library/Application Support/Sentry/settings.json` says `fahrenheit`; the three failing files never pin the unit. Make those tests pin `TemperatureUnit.display` (as `TemperatureUnitTests` does) or find the store that loads the real file. (The main checkout has uncommitted edits to exactly these three test files — check before duplicating.)
- **Remaining `TO-FILL(support-email)` markers** now that the address exists: `docs/privacy-policy.md:175`, `docs/pages-site/privacy-policy.md:175` (both covered by the sync above) and `docs/privacy-policy-checkout-draft.md:212`. Replace with `getsentryapp@gmail.com`.

---

*How to keep this page true:* when you close an item, move it to "Already
done" with its proof; when you discover a new one, put it in the right
bucket with a file:line. Do not add anything you have not verified.
