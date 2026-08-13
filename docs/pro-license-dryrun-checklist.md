# Pro license end-to-end dry run

Maintainer-facing. This is the checklist a human walks through **before
flipping checkout live**: one complete test-mode purchase, from the
merchant's checkout page to a revoked license disappearing from a real Mac.
Every step names what to verify, the expected result, and the likely ways it
fails. Nothing here is automated on purpose — the point is to watch the
whole pipeline with your own eyes once, in test mode, before a stranger's
money enters it.

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
4. **A license pane in Settings.** `LicenseProEntitlementStore.installLicense`
   and `removeLicense` exist and are tested, but no Settings pane calls
   them yet — there is currently nowhere in the UI to paste a blob. That
   pane (paste field, denial-reason display, remove button, seat/issue-date
   display) has to ship in the same release as checkout.
5. **Revalidation wiring.** `AppDelegate` constructs the entitlement store
   with `activationClient: nil` and `revalidationPolicy: .never`. When the
   D1 client exists, both change at that one composition-root call site:
   pass the concrete client and switch the policy to `.standard` (14-day
   offline grace). The two must flip **together and only together** —
   enabling `.standard` without a client permanently locks out every
   licensed user 14 days after activation, which is exactly the failure
   `LicenseRevalidationPolicy`'s doc comment exists to prevent.

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
   - Verify: the license area in Settings reports "No license is installed
     on this Mac." — the `.noLicense` state, not "This build of Sentry has
     no license verification key embedded…".
   - Expected: `.noLicense`. Pro features locked; Insights shows the top
     two findings free and honest locked previews for the rest.
   - Failure modes: the build-gap message means the production public key
     was not embedded (or was mis-pasted — a malformed key surfaces the
     same way, by design; see `LicenseKeys.productionPublicKey`). Fix the
     constant, rebuild, restart the checklist.
   - **Blocked until:** production key embedded (prerequisite 3), license
     pane exists (prerequisite 4).

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
     (`https://github.com/malekTheCoder/Sentry/issues`). The sending and
     reply-to address is TO-FILL(support-email).
   - Expected: blob copied from the email verifies identically to the blob
     inspected in step 4.
   - Failure modes: spam foldering (check the domain's SPF/DKIM); a "copy
     license" button that grabs a truncated string; smart-quote or
     zero-width-character injection by the template engine (surfaces as
     `.malformed` on paste).
   - **Blocked until:** issuance backend (task D1) — the mailer is part of
     it.

6. **Buyer pastes the blob into Settings; activation succeeds.**
   - Do: on the test Mac, paste the blob from the email into the license
     field — deliberately sloppily, with leading/trailing whitespace and a
     newline (the verifier trims; the tests pin this).
   - Verify: activation succeeds immediately and **offline** — this path
     is pure local verification, no network. The UI attributes the unlock
     to a license (`ProUnlockSource.license`), not the developer override.
     Pro features unlock — in code today the entitlement gate is
     `ProFeature.protectionInsights`, so at minimum confirm all Insights
     findings are now shown in full. `settings.json`
     (`~/Library/Application Support/Sentry/settings.json`) now contains
     `proLicenseBlob` and `proLicenseLastVerifiedAt` (install stamps the
     verification timestamp).
   - Expected: entitled, seat count 3 and issue date displayed from the
     payload.
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
   - **Blocked until:** license pane (prerequisite 4) and production key
     (prerequisite 3). The verification logic itself is already exercised
     by the test suite with a test-only key.

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
     `.standard`, trigger a revalidation (however the release exposes it —
     scheduled or a manual "verify now").
   - Verify: the app calls `revalidate(licenseID:)` with the payload's
     `licenseID`; the server answers still-valid;
     `proLicenseLastVerifiedAt` in `settings.json` moves to now;
     entitlement is unchanged. If the server returns a refreshed blob, the
     app verifies it locally before installing — a server response is
     input, not authority (`testActivateVerifiesTheServerBlobLocallyBeforeInstalling`
     pins the same principle for activation).
   - Expected: timestamp refreshed, nothing else visibly changes.
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
    - Do: trigger revalidation on the test Mac again.
    - Verify: the server answers revoked; the app **removes the license**
      — Pro locks, `proLicenseBlob` and `proLicenseLastVerifiedAt` are
      cleared from `settings.json`, and Settings reads "No license is
      installed on this Mac." (`testRevalidateRevokedRemovesTheLicense`
      pins this). Relaunch and confirm it does not resurrect.
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

## Open questions

- The marketing Pro feature list (fan-control writes, keep-awake release
  rules, process-match alert rules, custom theme editor, off-LAN remote
  sync pairing, history export + extended retention, Protection Insights)
  is wider than the entitlement gate in code: `ProFeature` has exactly one
  case, `.protectionInsights`. Every other advertised Pro feature must be
  added as a `ProFeature` case and gated before checkout goes live, or it
  ships free and the license unlocks less than the marketing claims.
- Seat enforcement: `seats` is displayed, deliberately not enforced
  client-side (see `LicensePayload`'s doc comment). If 3-Mac enforcement
  is wanted, it is an issuance-side activation count — decide whether D1
  does this at launch or later.
- Whether the checkout release ships revalidation at all (steps 8–10) or
  paste-only activation with revalidation in a follow-up. The privacy
  policy draft (`privacy-policy-checkout-draft.md`) currently describes a
  paste-only release; shipping revalidation adds a network path and
  requires another policy revision first.
