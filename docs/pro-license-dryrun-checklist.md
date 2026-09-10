# Pro license end-to-end dry run

Maintainer-facing. This is the checklist a human walks through **before
flipping checkout live**: one complete test-mode purchase, from the
merchant's checkout page to a revoked license disappearing from a real Mac.
Every step names what to verify, the expected result, and the likely ways it
fails. Nothing here is automated on purpose — the point is to watch the
whole pipeline with your own eyes once, in test mode, before a stranger's
money enters it.

**Reconciled 2026-09-10 against `main` at `661d2e0`** by reading
`SentryKit/Pro/License.swift`, `LicenseActivation.swift`,
`LicenseProEntitlementStore.swift`, `ProEntitlement.swift`, and
`ProGate.swift` in full, plus the composition root in
`Sentry/App/AppDelegate.swift`. Every claim about what exists and what is
deliberately absent below was checked against that source; the two that
had drifted (prerequisite 5's wording, and the first open question) are
corrected in place. See [`STATUS.md`](STATUS.md) for the cross-document view.

**Updated for the UI half (Part 5a, `feat/pro-purchase-ui`).** The app's
side of the purchase and activation path now exists: Settings ▸ Sentry Pro
(`Sentry/Settings/Panes/ProLicensePane.swift`, state machine in
`Sentry/Settings/ProLicenseActivationModel.swift`), a Buy affordance gated
on a real checkout address (`Sentry/App/ProPurchase.swift`,
`AppCredits.proCheckoutURLString`), and a daily revalidation scheduler
(`SentryKit/Pro/LicenseRevalidationScheduler.swift`) that is wired into
`AppDelegate` and inert until a client exists. Prerequisites 4 and 5 below
are rewritten accordingly; the new "What Part 5b wires up" section at the
end is the exact remaining list.

The code side of every claim below is real and in this repository:
`SentryKit/Pro/License.swift` (blob format, Ed25519 verification,
entitlement policy), `SentryKit/Pro/LicenseActivation.swift` (the
activation/revalidation seam), `SentryKit/Pro/LicenseProEntitlementStore.swift`
(install/remove/revalidate wiring), and
`SentryTests/LicenseProEntitlementTests.swift` (the pinned-date test suite).
The *issuance* side — the merchant account, the checkout webhook, the
service that mints and emails licenses (**task D1**) — deliberately lives
nowhere in this repository and does not exist yet. Steps that need it are
marked **Blocked until** accordingly.

## What must exist before this dry run can start

In dependency order:

1. **Merchant account** (Paddle, Lemon Squeezy, or similar merchant of
   record) with the Pro product configured: one-time purchase, $19.99
   regular / $14.99 launch price, licensed for 3 Macs, no subscription.
   Does not exist yet.
2. **Issuance backend (task D1)**: receives the merchant's purchase
   webhook, mints a `LicensePayload`, signs it with the production private
   key, composes the `sentry-pro-v1` blob, and emails it to the buyer.
   Does not exist yet.
3. **Production Ed25519 key pair.** `LicenseKeys.productionPublicKeyBase64`
   in `SentryKit/Pro/License.swift` is `nil` today. The owner generates the
   pair once, offline (the exact one-liner is in that file's doc comment),
   stores the private half in the issuance service's signer and a password
   manager, and pastes the public half into that constant. Until then no
   blob can verify in any build, and the app says so on screen
   (`LicenseDenialReason.verificationUnavailableInThisBuild`).
4. ~~**A license pane in Settings.**~~ **Done.** Settings ▸ Sentry Pro
   (`Sentry/Settings/Panes/ProLicensePane.swift`): paste field, Activate,
   `LicenseDenialReason.explanation` on every rejection, seats / issued /
   expiry from the payload, Remove License (with confirmation), and the Buy
   section while locked. The key-exchange path (`activate(licenseKey:)`)
   and "Confirm with Licensing Server Now" are built but render only when
   `LicenseProEntitlementStore.hasActivationBackend` is true — never today.
   Driven end to end in `SentryTests/ProLicenseActivationModelTests.swift`
   against the TEST-ONLY `StubLicenseActivationClient`
   (`SentryTests/LicenseTestSupport.swift`).
5. **Revalidation wiring — scheduler done, client not.** `AppDelegate`
   constructs the entitlement store passing only `settingsStore:` and
   `publicKey: LicenseKeys.productionPublicKey`, so it takes the
   initializer's defaults — `activationClient: nil` and
   `revalidationPolicy: .never`. A `LicenseRevalidationScheduler`
   (`SentryKit/Pro/LicenseRevalidationScheduler.swift`, modeled on
   `UpdateController`'s daily Sparkle check) is now constructed next to it
   and started in `applicationDidFinishLaunching`; it consults
   `store.isOnlineRevalidationArmed` and, with today's arguments, records
   `.inert` and creates no task (pinned by
   `SentryTests/LicenseRevalidationSchedulerTests.swift`). When the D1
   client exists, both store arguments change at that one call site: pass
   the concrete client and switch the policy to `.standard` (14-day offline
   grace), and the scheduler starts checking daily with no further edit.
   The two must flip **together and only together** — enabling `.standard`
   without a client permanently locks out every licensed user 14 days after
   activation, which is exactly the failure `LicenseRevalidationPolicy`'s
   doc comment exists to prevent (and which the scheduler cannot rescue:
   there is nobody to call).
6. **The checkout address.** `AppCredits.proCheckoutURLString`
   (`SentryKit/Models/AppCredits.swift`) is the placeholder
   `REPLACE-WITH-THE-SENTRY-PRO-CHECKOUT-URL`. Every locked surface reads
   `AppCredits.proCheckoutURL`, which is nil for the placeholder (and for
   any non-HTTPS or hostless value), and renders the marketing site's own
   "isn't on sale yet" sentence instead of a button. Pasting the vendor's
   HTTPS checkout URL into that one constant turns on the Buy button in
   the Insights upsell card, the Theme pane's upsell card, the Sync pane's
   locked row, and Settings ▸ Sentry Pro, and flips the Alerts pane's
   locked footer to point at the pane — all at once, from one line
   (`SentryTests/ProPurchaseAffordanceTests.swift`).

## What can be verified today, with none of the above

- Run the test suite: `SentryTests/LicenseProEntitlementTests.swift` covers
  blob round-trips, tamper/wrong-key/truncation rejection, expiry
  boundaries, grace-window boundaries, install/remove persistence,
  server-blob re-verification, and revocation removal — all with
  runtime-generated test keys and pinned dates. Green today; keep it green.
- Steps 4 and 6 below can be *rehearsed* end to end with a test key
  (generate a throwaway pair, sign a payload, verify it in a debug build
  whose `publicKey` is the test key) — the tests already do exactly this.
  What a rehearsal cannot prove is the production pipeline: real key, real
  webhook, real email.
- The UI layer: `ProLicenseActivationModelTests` (paste activates offline;
  wrong key, mangled paste, expired blob, key-with-no-backend, server
  rejection, transport failure, server forgery each land in their own
  typed failure with a sentence and persist nothing; removal clears
  everything; confirm-with-server still-valid/revoked),
  `LicenseRevalidationSchedulerTests` (inert in the shipped configuration,
  repeats when armed, absorbs transport errors, removes on revoked, stops),
  `ProPurchaseAffordanceTests` and the checkout cases in `AppCreditsTests`
  (placeholder → no button, real HTTPS → button, plaintext refused).

## The dry run

For every step: do it in the merchant's **test mode**, with a buyer email
address you control.

1. **Preflight the build.**
   - Do: install the release-candidate build from the DMG
     (`https://github.com/malekTheCoder/Sentry/releases/latest/download/Sentry.dmg`
     once published, or the local release build) on a clean test Mac
     (macOS 14 or later). Make sure Settings ▸ Advanced ▸ Developer's Pro
     override is **off** — an override left on would mask every failure in
     this checklist.
   - Verify: Settings ▸ Sentry Pro's Status section reads "No license on
     this Mac" over "No license is installed on this Mac." — the
     `.noLicense` state, not "This build of Sentry has no license
     verification key embedded…". (With the override on it would instead
     read "No license — unlocked by the developer override", which is
     your cue to turn it off.)
   - Expected: `.noLicense`. Pro features locked; Insights shows the top
     two findings free and honest locked previews for the rest.
   - Failure modes: the build-gap message means the production public key
     was not embedded (or was mis-pasted — a malformed key surfaces the
     same way, by design; see `LicenseKeys.productionPublicKey`). Fix the
     constant, rebuild, restart the checklist.
   - **Blocked until:** production key embedded (prerequisite 3).

2. **Test-mode purchase at the merchant.**
   - Do: buy the Pro product through the merchant's checkout with a test
     card.
   - Verify: the order shows the right product name, one-time (not
     recurring), the launch price $14.99, and copy stating the license
     covers 3 Macs. The checkout collects the buyer's email.
   - Expected: order completes; the merchant dashboard shows a test-mode
     order.
   - Failure modes: product accidentally configured as a subscription;
     wrong price or currency handling; test order landing in live mode
     (check the mode banner in the dashboard, not just the receipt).
   - **Blocked until:** merchant account (prerequisite 1).

3. **Webhook fires and is authenticated.**
   - Do: watch the issuance service's log for the purchase event.
   - Verify: the service received the webhook, **validated the merchant's
     webhook signature before acting**, and matched the event to the test
     order.
   - Expected: exactly one issuance per order, even if the merchant
     retries delivery (webhook retries are normal — issuance must be
     idempotent on the order ID).
   - Failure modes: webhook secret mismatch (events silently dropped or,
     worse, accepted unauthenticated); duplicate deliveries minting two
     licenses; test-mode events routed to the live issuance path.
   - **Blocked until:** issuance backend (task D1) and merchant account.

4. **Issuance mints and signs the blob.**
   - Do: inspect the minted license before it is emailed.
   - Verify the payload field by field against `LicensePayload`:
     - `licenseID`: a fresh UUID string (this is the handle revalidation
       uses — it must be stored server-side against the order).
     - `emailSHA256`: SHA-256 of the buyer email **trimmed and lowercased
       first**, as lowercase hex — the exact normalization in
       `LicensePayload.emailHash(_:)`. Hash the test address yourself and
       compare.
     - `seats`: 3.
     - `issuedAt`: epoch seconds as an integer (not a float).
     - `expiresAt`: **absent/null** — the Pro license is perpetual, and
       `nil` is the only spelling of perpetual the verifier accepts (no
       sentinel far-future date).
   - Verify the blob structure: three dot-separated segments,
     `sentry-pro-v1.<base64url payload JSON>.<base64url signature>`,
     base64url **unpadded** (`-`/`_`, no `=`), and — critically — the
     Ed25519 signature is over **the exact payload bytes placed in segment
     two**, not over a re-serialization. Then run the blob through
     `SignedLicense.verify` with the production public key (a three-line
     Swift script against SentryKit, or a debug build) and confirm
     `.valid` with the expected payload.
   - Expected: `.valid`, every field round-tripping exactly.
   - Failure modes: signing a re-encoded JSON whose key order or number
     formatting differs from the transmitted bytes (verifies on the
     server, `.signatureInvalid` on the Mac — the classic); standard
     base64 or padding in a segment (`.malformed`); float epoch seconds
     (payload decode fails → `.malformed`); email hashed without the
     normalization (activates fine but support can never match a license
     to its buyer); wrong signing key (`.signatureInvalid`).
   - **Blocked until:** issuance backend (task D1).

5. **The license email arrives.**
   - Do: check the buyer inbox.
   - Verify: the mail arrives at the address used at checkout, contains
     the full blob in a plain-text form that survives copying (the
     base64url alphabet was chosen to survive email, but an HTML template
     can still wrap or style it into something un-copyable — a `<pre>`
     block or an attached `.txt` is safest), states what to do with it
     ("paste into Settings"), and names where to get help: GitHub Issues
     (`https://github.com/malekTheCoder/Sentry/issues`) and the published
     support address, `getsentryapp@gmail.com`, which should also be the
     mail's reply-to. (The *sending* address is the mailer's — a D1
     decision.)
   - Expected: blob copied from the email verifies identically to the blob
     inspected in step 4.
   - Failure modes: spam foldering (check the domain's SPF/DKIM); a "copy
     license" button that grabs a truncated string; smart-quote or
     zero-width-character injection by the template engine (surfaces as
     `.malformed` on paste).
   - **Blocked until:** issuance backend (task D1) — the mailer is part of
     it.

6. **Buyer pastes the blob into Settings; activation succeeds.**
   - Do: on the test Mac, paste the blob from the email into Settings ▸
     Sentry Pro's license field and press Activate — deliberately
     sloppily, with leading/trailing whitespace and a newline (the model
     trims before classifying; `testPastedBlobActivatesOfflineWithNoBackend`
     pins this).
   - Verify: activation succeeds immediately and **offline** — this path
     is pure local verification, no network. The UI attributes the unlock
     to a license (`ProUnlockSource.license`), not the developer override.
     Pro features unlock — all six `ProFeature` cases are gated in code and
     one license unlocks every one of them
     (`LicenseProEntitlementStore.isUnlocked`, `:114–126`), so confirm each:
     all Insights findings shown in full (`.protectionInsights`), a
     release rule can be added to a keep-awake (`.conditionalKeepAwake`),
     a process-match alert rule can be created (`.processMatchAlerts`),
     the theme editor opens (`.customThemes`), a remote pairing code can be
     minted in Settings ▸ Sync (`.remoteSync`), and history export is
     offered (`.historyExport`). `settings.json`
     (`~/Library/Application Support/Sentry/settings.json`) now contains
     `proLicenseBlob` and `proLicenseLastVerifiedAt` (install stamps the
     verification timestamp).
   - Expected: entitled; the Status section shows "Sentry Pro is active on
     this Mac", Covers "3 Macs", the issue date, and Expires "Never — this
     is a perpetual license"; the field clears; the Buy section disappears
     and a Remove section appears.
   - Failure modes, each with its own on-screen sentence
     (`LicenseDenialReason.explanation` — verify the *right* one appears):
     - `.malformed` — truncated or mangled paste. Re-copy the whole blob.
     - `.signatureInvalid` — the issuance service and the shipped build
       disagree about the key pair. Stop the launch; nothing sold before
       this is fixed would activate.
     - `.unsupportedFormat` — issuance emitted a prefix other than
       `sentry-pro-v1`.
     - `.expired` — issuance set `expiresAt` on what must be a perpetual
       license.
     - A rejected blob persists **nothing** — verify `settings.json` still
       has no `proLicenseBlob` after a failed paste.
   - **Blocked until:** production key (prerequisite 3). The pane and the
     verification logic are both exercised by the test suite with a
     test-only key.

7. **Entitlement survives a relaunch.**
   - Do: quit and relaunch the app.
   - Verify: still entitled, still attributed to the license — the store
     seeds itself from `settings.json` at construction
     (`testStoreSeededFromSettingsEntitlesOnRelaunch` pins this).
   - Expected: no re-activation, no network, no prompt.
   - Failure modes: settings write raced shutdown (the store writes
     through the debounced settings pipeline — pause a few seconds before
     quitting if in doubt, then confirm the blob is on disk).

8. **Revalidation succeeds.**
   - Do: with the D1 activation client wired and the policy at
     `.standard`, trigger a revalidation — either wait for
     `LicenseRevalidationScheduler`'s tick (immediately at launch, then
     daily) or press "Confirm with Licensing Server Now" in Settings ▸
     Sentry Pro (the button exists only when a client is wired).
   - Verify: the app calls `revalidate(licenseID:)` with the payload's
     `licenseID`; the server answers still-valid;
     `proLicenseLastVerifiedAt` in `settings.json` moves to now;
     entitlement is unchanged. If the server returns a refreshed blob, the
     app verifies it locally before installing — a server response is
     input, not authority (`testActivateVerifiesTheServerBlobLocallyBeforeInstalling`
     pins the same principle for activation).
   - Expected: timestamp refreshed; "Last confirmed" in the Status section
     moves to now; the manual button reports "Confirmed with the licensing
     server just now."; nothing else visibly changes.
   - Failure modes: an *unreachable* server must surface as a transport
     error and leave the license alone — the 14-day grace window exists
     precisely so offline Macs aren't punished; a server that answers
     still-valid with a malformed refreshed blob must be rejected locally
     with nothing installed.
   - **Blocked until:** issuance backend (task D1) and the composition-root
     flip (prerequisite 5).

9. **Refund the test purchase; the license is revoked server-side.**
   - Do: issue a refund for the test order in the merchant dashboard.
   - Verify: the refund webhook reaches the issuance service,
     authenticated like the purchase webhook, and the service marks the
     `licenseID` revoked so subsequent `revalidate` calls answer revoked
     (with a human-readable reason — it is display text in the app).
   - Expected: server-side state flips; the Mac knows nothing yet.
   - Failure modes: refund webhook not subscribed (revocation never
     happens — refunded licenses live forever); chargeback events handled
     differently from refunds (both must revoke).
   - **Blocked until:** merchant account and issuance backend (task D1).

10. **The app observes the revocation on next revalidation.**
    - Do: trigger revalidation on the test Mac again (scheduled tick or
      the manual button, as in step 8).
    - Verify: the server answers revoked; the app **removes the license**
      — Pro locks, `proLicenseBlob` and `proLicenseLastVerifiedAt` are
      cleared from `settings.json`, and Settings ▸ Sentry Pro reads "No
      license on this Mac" (`testRevalidateRevokedRemovesTheLicense`,
      `testRevokedAnswerOnAScheduledTickRemovesTheLicense`, and
      `testConfirmRevokedRemovesTheLicenseAndSaysWhy` pin this; the manual
      button also shows the server's reason). Relaunch and confirm it does
      not resurrect.
    - Expected: locked, cleanly, with no error state left behind.
    - Failure modes: the structural one — revocation only propagates
      through revalidation. Under the shipped `.never` policy nothing ever
      calls home, so if the release ships checkout without the D1 client,
      a refunded license keeps working forever on any Mac it reached.
      Acceptable for a launch window as a known trade-off, but it must be
      a *decision*, recorded, not an accident.
    - **Blocked until:** issuance backend (task D1).

11. **Clean up test mode before going live.**
    - Do: decide, before the first live sale, whether test-mode purchases
      are signed with the production key or a staging key. Production-key
      test blobs are indistinguishable from paid licenses (revoke them
      after the dry run); staging-key blobs won't activate in shipping
      builds (rerun step 6 against a staging build). Either works — pick
      one and write it down.
    - Verify: no test license remains in good standing server-side; the
      test Mac is back to `.noLicense`; the merchant account is switched
      to live mode with the live webhook endpoint configured.

## What Part 5b wires up, the moment a vendor account exists

Everything below is on the app's side of the seam and is the *complete*
remaining list; nothing else in the app needs to change for checkout to
work. In order:

1. **Paste the checkout URL** into `AppCredits.proCheckoutURLString`
   (`SentryKit/Models/AppCredits.swift`), replacing the placeholder. Must
   be HTTPS with a host or `proCheckoutURL` stays nil and no button
   appears. `testShippedProCheckoutConstantIsThePlaceholderOrALiveHTTPSAddress`
   catches a half-edited value.
2. **Embed the production public key** in
   `LicenseKeys.productionPublicKeyBase64` (prerequisite 3) — otherwise
   every pasted blob is denied with `.verificationUnavailableInThisBuild`,
   which the pane shows verbatim.
3. **Write the concrete `LicenseActivationClient` conformer** against the
   vendor's API — `activate(licenseKey:)` and `revalidate(licenseID:)`,
   nothing more (`SentryKit/Pro/LicenseActivation.swift`). Decide there
   what a key-rejected-by-server error looks like: the pane shows whatever
   the thrown error's `localizedDescription` says
   (`ProLicenseActivationModel.Failure.activationFailed`), so make it a
   `LocalizedError` with a user-readable sentence, and keep transport
   errors distinguishable from rejections if the vendor's API allows it.
   A revoked answer's `reason` is also shown on screen verbatim.
4. **Flip the composition root** — `Sentry/App/AppDelegate.swift`,
   the `LicenseProEntitlementStore(...)` call — to pass the client *and*
   `revalidationPolicy: .standard` together. That single edit also arms
   `LicenseRevalidationScheduler` (already started there) and makes
   Settings ▸ Sentry Pro show the key field caption, the "Last confirmed"
   row, and the "Confirm with Licensing Server Now" button.
5. **Decide whether 1.x ships revalidation at all** (the last open
   question below). If not, do step 3 and skip step 4: the pane's
   paste-a-license path, the Buy button, and Remove all work with
   `activationClient: nil` and `.never`, and a refunded license keeps
   working forever on any Mac it reached — record that as a decision.
6. **Revise the privacy policy** if step 4 is taken: revalidation adds a
   network path the current draft (`privacy-policy-checkout-draft.md`)
   says does not exist.
7. **Walk this dry run** end to end in the vendor's test mode.

## Open questions

- ~~The marketing Pro feature list is wider than the entitlement gate in
  code: `ProFeature` has exactly one case, `.protectionInsights`.~~
  **Resolved.** `ProFeature` (`SentryKit/Pro/ProEntitlement.swift:30–37`)
  now has six cases matching the marketing list — `.protectionInsights`,
  `.conditionalKeepAwake`, `.processMatchAlerts`, `.customThemes`,
  `.remoteSync`, `.historyExport` — and every one is consulted at a real
  call site (`InsightsViewModel.swift:120`, `AppDelegate.swift:685–695` and
  `:1024–1027`, `AlertsPane.swift:99`, `ThemePane.swift:54`,
  `SettingsView.swift:329–335`, `OnboardingCoordinator.swift:226`).
  Fan-control writes were on the list until fan control was removed
  entirely; Sentry reads fan speeds and never sets them. What remains is
  the *product* question of whether that list is final — a new paid
  feature is a new case plus a compiler-forced decision in both
  `isUnlocked` switches.
- Seat enforcement: `seats` is displayed, deliberately not enforced
  client-side (see `LicensePayload`'s doc comment). If 3-Mac enforcement
  is wanted, it is an issuance-side activation count — decide whether D1
  does this at launch or later.
- Whether the checkout release ships revalidation at all (steps 8–10) or
  paste-only activation with revalidation in a follow-up. The privacy
  policy draft (`privacy-policy-checkout-draft.md`) currently describes a
  paste-only release; shipping revalidation adds a network path and
  requires another policy revision first.
