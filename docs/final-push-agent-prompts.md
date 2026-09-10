# Sentry — the final push to ship: prompts for Aniketh's agents

Written 2026-09-10, against `main` at commit `e80378c` (1687 tests passing, 0 failures).
Covers all four surfaces — Mac app, iOS app, Apple Watch app, and the marketing
website — plus monetization, since that is the one pillar with genuinely nothing
built yet on the transactional side.

Every claim below was checked against the actual source, the actual live URLs, and
the actual signing-identity state on disk before being written — not copied from the
existing checklist docs, because **the existing checklist docs are themselves stale**,
and untangling that is Prompt 1, on purpose, run first.

---

## Part 0 — What only a human can do (nothing below is an agent task)

Read this first. No prompt in this document assigns any of the following to an
agent, because none of them are technically possible for one: they require an Apple
ID with paid developer access, a payment processor's merchant-onboarding flow
(banking details, tax ID, identity verification), or a business/legal judgment call
that isn't Sentry's code to make. Everything else in this document — everything —
is scoped so an agent can actually finish it.

1. **Get a Developer ID Application certificate for team H7T2D2GL7U, installed in a
   keychain an agent can build from.** As of this writing, `security find-identity
   -v -p codesigning` returns zero valid identities on every machine that has
   touched this repo. Nothing in the release pipeline (Prompt 4) can even begin
   until this exists. This has been the single blocking item for weeks.
2. **Store a notarization credential** (`xcrun notarytool store-credentials`) on
   whichever machine will run releases — needs an app-specific password from
   appleid.apple.com, tied to the Apple ID with paid developer access.
3. **Pick a payment vendor and open the merchant account** — Paddle, Lemon Squeezy,
   or similar. This is the one thing every piece of the monetization work (Prompt 5)
   is blocked behind. `SentryKit/Pro/LicenseActivation.swift`'s own doc comment says
   plainly why no agent has built this: "those come with an account, API keys,
   webhook endpoints, and a store URL that only the project owner can create."
   Decide the price while you're there — the website already says "Later... no
   price set yet," honestly, and someone has to pick a number.
4. **Generate the production Pro-license signing keypair yourself, once you have a
   vendor**, the same way you generated the Sparkle key this session — an agent
   should not be trusted with a key that, if lost, invalidates every license ever
   sold. Prompt 5 explains exactly where it plugs in once you have it.
5. **App Store Connect data entry** — pasting the already-drafted content from
   `docs/asc-metadata-draft.md` into the actual ASC web UI: age rating questionnaire
   answers, App Privacy questionnaire answers, the Support/Marketing URL fields,
   category selection, uploading the screenshots Prompt 3 produces, and hitting
   submit. No agent has ASC access.
6. **EU Digital Services Act trader-status verification.** Legal/business
   verification with Apple directly; has not been started as of this writing; takes
   real calendar time, so start it in parallel with everything else, not after.
7. **The app name** — provisional pending a trademark decision. `docs/asc-metadata-draft.md`
   is already written so a rename is a find-and-replace in that one file; the
   decision itself is yours.
8. **Record the App Review demo video** — a real screen recording of the Mac app
   running, per the shot list already drafted in `docs/asc-metadata-draft.md`
   ("Demo video — shot list and narration script"). An agent can hand you a shot
   list; it cannot operate a real Mac's screen recorder for you or narrate it in
   your voice for a human reviewer's benefit.
9. **Decide what happens to the public v1.0 GitHub release.** It has real downloads
   (4 as of 2026-08-16, almost certainly more since) with a *placeholder* Sparkle
   key permanently baked into that exact binary — those specific copies can never
   receive any future update, ever, because the key is compiled in. Prompt 4's dry
   run will flag this again; deciding whether to pull it, replace it, or post a
   manual-reinstall notice is a call only you two should make.

Everything past this point is scoped so an agent can drive it to completion, with
each prompt explicitly stating the narrow human-only step it hands back if one
exists.

---

## Part 1 — Run this first, alone: reconcile the docs with reality

```
Work in your own worktree: from the repo root run
`git worktree add -b docs/reconcile-appstore-readiness worktrees/reconcile-readiness main`,
and work only there.

TASK: `docs/appstore-review-readiness.md`, `docs/release-checklist.md`, and the "Open
items this draft cannot settle" section of `docs/asc-metadata-draft.md` describe several
bugs and gaps as still-open that are already fixed in current `main`. Trusting these docs
wastes time re-fixing solved problems and — worse — could hand a reviewer review-notes
text describing bugs that no longer exist. Your job is to make every claim in these
documents true again, proven against the actual source, not asserted. Do the same for
`docs/pro-license-dryrun-checklist.md` — it may also be stale relative to the current
state of `SentryKit/Pro/`.

METHOD: for every unchecked `- [ ]` item and every claim in the "Open items" section,
do not take the document's word for it. Grep or read the actual code it points at. Only
after confirming the current behavior should you either (a) check the item off with a
one-line note on what proves it's done and which commit likely did it (`git log --oneline
-S "<distinctive string>" -- <file>` finds it), or (b) leave it open and, if the
description is now inaccurate (file moved, line number shifted, behavior changed in a
way that's related but not identical), correct the description to match current reality.

Specific starting points, already verified true as of commit e80378c — confirm they
still hold and check them off with the evidence:
- `MockDataSource.swift` — is the seeded device name still "Demo MacBook Pro"?
- `SleepStatusCard.swift` — does the mock-path keep-awake tap still say "Demo mode —
  there's no Mac connected, so nothing was sent." rather than "Sent, but no reply..."?
- `StatsCoordinator.swift` — is `protectionScoreStorage` still wired into the outgoing
  snapshot? Is `GetProtectionScoreIntent` still honest about demo mode and no-score-yet?
- `RootTabView.swift` / `DemoDataBanner.swift` — does the banner still cover all four
  tabs, Alerts included?
- The widget views — do all three families still check `sourceIsDemoData`?
- `AppCredits.swift` — do `privacyPolicyURLString` and `macAppDownloadURLString` still
  resolve, and are they still wired into `AboutView` and `OnboardingView`?
- Live-check these with curl; all should return 200, not 404:
  `https://malekthecoder.github.io/Sentry/privacy-policy`,
  `https://malekthecoder.github.io/Sentry/appcast.xml`,
  `https://malekthecoder.github.io/Sentry/support`,
  `https://malekswilam.dev/SentryWebsite/`.
  (If your environment has no outbound network access, say so explicitly in your report
  rather than guessing at the result — do not mark anything verified that you couldn't
  actually check.)
- `SentryKit/Pro/` — read `License.swift`, `LicenseActivation.swift`,
  `LicenseProEntitlementStore.swift`, and `ProGate.swift` in full, and confirm
  `docs/pro-license-dryrun-checklist.md`'s description of what exists versus what's
  deliberately absent (the issuance/checkout side) still matches. This doc and code pair
  will matter enormously to whoever picks up Prompt 5, so it needs to be exactly right.

Do NOT check off anything you haven't personally verified against the source or a live
request. Do NOT assume something is done because it "sounds like the kind of thing that
would have been fixed" — several items on this list are the reverse case, genuinely still
open, and the whole point of this task is telling the two kinds apart correctly.

After reconciling, write one more artifact: `docs/STATUS.md`, a single page someone can
read in under a minute to know exactly what's left, with no need to cross-reference five
documents. Organize it in exactly three buckets: **Human-only** (nothing an agent can do —
cross-reference Part 0 of the prompt document you were given, if you have access to it;
otherwise reconstruct the list from what you find: Developer ID cert, notarization
credential, payment vendor account, ASC data entry, DSA verification, app name, demo
video, the v1.0 release decision), **Blocked** (agent-doable but waiting on something
above — most of the release pipeline and anything needing the real payment vendor's API),
and **Ready for an agent right now** (everything else still open). This file is what every
other agent working on this codebase should read first from now on, so make it accurate
and make it something you'd trust a total stranger to act on without double-checking you.

CONSTRAINTS: this is a documentation-only task. Do not modify any `.swift` file. If you
find a genuine, previously-unknown code bug while verifying a claim, do not fix it —
note it in your report with file:line and enough detail that a separate task can address
it, and leave the code untouched.

Run the full test suite before committing even though you shouldn't have touched any
source — `xcodegen generate` then
`xcodebuild -project Sentry.xcodeproj -scheme Sentry -configuration Debug
-derivedDataPath ~/Library/Developer/Sentry-DD-DOCS test` — as a guard that you didn't
accidentally touch something you shouldn't have. Clean up that derived-data directory
when done.

Commit on your branch with a clear message. Report: the corrected checklists, a list of
every item you flipped from open to done with its proof, any item whose description you
had to correct, any new bug you found and are handing off (not fixing), and the full text
of `docs/STATUS.md`.
```

---

## Part 2 — iOS: the one missing link

```
Work in your own worktree: from the repo root run
`git worktree add -b feat/support-url worktrees/support-url main`, and work only there.

CONTEXT: Sentry already has a published, live support page —
`https://malekthecoder.github.io/Sentry/support` (verify this resolves before doing
anything else; if it does not, stop and report rather than building on top of a broken
assumption). It documents how to file a bug report and how to find a crash log. There is
a live support email too — `getsentryapp@gmail.com` — printed on both the published
privacy policy and the support page. But there is no in-app surface for either, and no
`supportURLString` constant anywhere in the codebase — App Store Connect's required
"Support URL" field currently has nothing correct to point at from inside this repo.

TASK: add a `supportURLString` constant to `SentryKit/Models/AppCredits.swift`, following
the exact pattern already established twice in that file for `privacyPolicyURLString` and
`macAppDownloadURLString` — same section style, same doc-comment rigor about why the
string is pinned and what breaks if the two ends (the constant and the live page) drift
apart. Read both existing constants and their full doc comments before writing this one;
match their voice exactly, including the "why this can't be corrected after an app ships"
reasoning both existing ones carry.

Then wire it into the same place those two are wired: `SentryMobile/Settings/AboutView.swift`'s
`privacyCard`-style layout. Decide whether a support link deserves its own card (matching
`privacyCard`'s structure — a small caps header, a `Link`, an explanatory sentence
underneath) or belongs folded into the existing privacy card as a second `Link` under the
same header. Look at how the file is laid out today and make the call that reads most
consistently with the existing two-card rhythm; explain your choice in a doc comment the
way the rest of this file's comments explain layout choices.

Check whether `OnboardingView.swift` already has a natural "if something goes wrong"
moment near where it surfaces the Mac-app download link, and if so, add the support link
there too. Do not invent a new onboarding step to hold it — that's a product decision, not
a code gap this task should make unilaterally.

VERIFICATION: curl `https://malekthecoder.github.io/Sentry/support` yourself if your
environment allows outbound network access. If it doesn't, say so explicitly in your
report and state that a human must verify HTTP 200 before this ships — do not claim you
verified something you couldn't actually check.

Add or extend a test analogous to whatever test currently proves
`AppCredits.privacyPolicyURL`/`macAppDownloadURL` parse correctly and match the pinned
string exactly (look for `AppCreditsTests.swift`). The new support URL needs the same
coverage.

`xcodegen generate` then
`xcodebuild -project Sentry.xcodeproj -scheme Sentry -configuration Debug
-derivedDataPath ~/Library/Developer/Sentry-DD-SUPPORT test` must pass. Also build the
iOS app for a simulator destination to confirm the new UI compiles and renders — find the
correct scheme and destination the same way earlier iOS work in this repo did (SentryMobile
scheme, an iPhone simulator). Clean up derived-data directories when done.

Commit on your branch with a clear message. Report: the exact string you pinned, where
you verified it resolves (or the explicit caveat if you couldn't check), what UI decision
you made and why, the test you added, and confirmation the iOS build succeeded.
```

---

## Part 3 — Watch app: verify, don't assume

```
Work in your own worktree: from the repo root run
`git worktree add -b audit/watch-final worktrees/watch-final main`, and work only there.

CONTEXT: no open TODO, FIXME, or "not implemented" marker exists anywhere in
`SentryWatch/` or `SentryWatchWidget/` as of this writing, and the watch UI, theme
fidelity, and relay-state honesty all had dedicated work earlier in this project's
history. This task exists to confirm that's still true rather than to find new work —
treat a clean report as a legitimate, valuable outcome, not a failure to find something
to fix.

TASK: audit the watch app end to end against the same standard the rest of this
document holds everything else to — nothing shown to the user may claim more than the
evidence supports.

1. Read every file under `SentryWatch/Pages/` and `SentryWatch/Theme/`. For each screen,
   confirm: does it correctly distinguish "live data from a reachable Mac" from "stale
   data because the Mac hasn't been heard from in a while" from "no data because nothing
   has ever paired"? Cross-check against `SentryKit/Watch/RelayedPalette.swift` and
   whatever staleness/freshness logic the relay layer already has — do not invent a new
   staleness policy if one already exists; verify the existing one is actually being used
   everywhere it should be.
2. Confirm the keep-awake surfaces on the watch (`WatchKeepAwakeIntent`,
   `WatchReleaseAwakeIntent`, the Keep Awake page) still correctly report state after the
   keep-awake lifecycle rework from earlier this project's history — specifically, that an
   indefinite hold started from the phone or Mac shows correctly on the watch, and that
   the watch never claims a hold is active past its actual end.
3. Confirm every one of the three built-in themes (`System`, `Ivory`, `One Dark` —
   verify this is still the current list against `Theme.builtInPresets` in
   `SentryKit/Settings/Theme.swift`, since it has changed before) renders correctly on
   the watch with no illegible or invisible controls, the same standard applied to the
   Mac app's toggle-contrast work. Use `ThemeContrast`'s existing helpers rather than
   eyeballing it, matching how that Mac-side work proved its claims with a test rather
   than a screenshot alone.
4. Confirm the watch complication (if `SentryWatchWidget` renders one) has an honest
   placeholder/demo state, matching the standard the phone's widgets already meet
   (`sourceIsDemoData` checked in all three phone widget families — verify the watch
   widget does the same if it's capable of showing invented data in any circumstance).

Fix anything you find that falls short of these standards, following this codebase's
argumentative doc-comment style (explain why, name the alternative you rejected) and its
existing test patterns for the area you're touching. If everything already holds, do not
manufacture a change to have something to commit — a report that says "verified, nothing
needed" is the correct and complete outcome of this task, and is exactly as valuable as
one that fixes something.

`xcodegen generate` then the full macOS suite
(`xcodebuild -project Sentry.xcodeproj -scheme Sentry -configuration Debug
-derivedDataPath ~/Library/Developer/Sentry-DD-WATCH test`) must pass regardless. Also
attempt a watchOS build for a simulator destination to confirm anything you changed
compiles; if you cannot determine the correct scheme/destination, say so in your report
rather than skipping verification silently. Clean up derived-data directories when done.

Commit on your branch (even a no-op verification commit updating a comment or test name
is fine if truly nothing else needed to change — but prefer to fold your findings into
`docs/STATUS.md` from Part 1 if that task has already run). Report every one of the four
checks above individually with its result, not just an overall verdict.
```

---

## Part 4 — Marketing website: full audit, not just the one bug already fixed

```
Work in your own worktree: from
`/Users/malekswilam/Developer/MacStatsProject/SentryWebsite` (a separate repo from the
main app — confirm with `git remote -v` that you're in `malekTheCoder/SentryWebsite`
before doing anything), run
`git worktree add -b audit/site-final worktrees/site-final main`, and work only there.

CONTEXT: this site had one focused correction already (removing false fan-control
claims and a stale theme count, commit `6410935`). This task is the broader sweep that
correction was a sample of, not a repeat of it — go back over the whole site, not just
the sections that were already touched.

TASK: every specific, checkable claim on this site must be true against the current
state of the app it's describing. For each one below, verify against the actual source
in the sibling `MacStat` repo (path: `../MacStat` relative to this repo, or wherever your
environment has it checked out) before touching anything — do not assume a claim is
wrong just because it's specific, and do not assume it's right because it sounds
plausible.

1. **Every numeric claim.** Grep the site for counts (tool counts, rule counts, theme
   counts, retention windows, cooldown minutes, anything with a digit attached to a
   feature name) and verify each against its source. As of the last check: "twenty
   tools," "fourteen rules," "30-minute" cooldown, and the three built-in themes were all
   confirmed accurate — re-verify them, since the underlying code may have moved again,
   and check every other numeric claim the same way.
2. **The pricing section.** It currently says Sentry Pro has "no price set yet" and "a
   single purchase when it happens, not a subscription." Confirm this is still accurate
   by reading `SentryKit/Pro/License.swift` and `LicenseActivation.swift` in the sibling
   repo — specifically, confirm the code still has no concrete purchase/checkout
   implementation, so the site's "Later" framing is still honest and not now understating
   something that actually shipped. If Part 0 item 3 (the payment vendor decision) has
   been made and Prompt 5 has landed a real checkout link, this section needs updating to
   match — check `docs/STATUS.md` (from Part 1) for the current truth before deciding
   which state you're in.
3. **The Pro feature list itself** — the six things called out as Pro-gated (longer
   history retention and file export, five conditional keep-awake release rules,
   process-matching alert rules, remote access from outside the local network). Confirm
   each still matches `ProGate.swift` and wherever else Pro-gating decisions live in the
   sibling repo. A stale gate list here is a promise the app doesn't keep, in either
   direction — check for features the site claims are Pro that are actually free, and
   the reverse.
4. **Every external link on the page** — privacy policy, support, the Mac download link,
   any GitHub links, social card, footer. Fetch each one (curl, if your environment
   allows outbound network access; if not, list them and say so explicitly rather than
   claiming verification) and confirm 200, not a redirect chain ending in 404.
5. **The 404 page and social card** — do they still reflect current app branding and
   messaging, or do they reference anything since removed (the fan-control section's
   removal is the known precedent; check whether the 404 page or social card text was
   written before or after that change and whether either mentions anything else that's
   since changed)?
6. **Mobile rendering.** Load the page at a phone-width viewport and confirm nothing
   breaks — this wasn't checked as part of the fan-control fix and may never have been
   verified at all.
7. **The Live Activity feature** — the sleep-control section already mentions it ("Start
   a keep-awake hold from the phone and it becomes a Live Activity with an End button in
   the Dynamic Island — drawn by the system from its deadline, so a timed hold stays
   right for hours with the app never running"). Confirm this description still matches
   `SentryKit/Models/KeepAwakeActivityState.swift` and the Live Activity implementation
   in the sibling repo's `SentryWidget/LiveActivity/` — this was new work relative to
   older parts of the site and is worth double-checking landed correctly in the copy.

Fix whatever you find, matching the existing site's writing voice exactly — read at least
three other section descriptions before writing new copy, and do not introduce a
noticeably different tone for your additions. Validate the HTML parses cleanly before
committing (an unclosed tag or stray close tag is a real risk when hand-editing a
1000+-line single file) — write a small Python or Node script using an HTML parser to
walk the tag stack and confirm balance, the same check used for the fan-control fix.

Do not touch anything related to payments/checkout beyond the verification in step 2 —
if the pricing section needs updating because Prompt 5 has landed real purchasing, that
update belongs with Prompt 5's own work or a dedicated follow-up, not bundled into a
general audit commit. Keep this commit about correctness of existing claims, not new
features.

Commit on your branch with a clear message describing every correction and citing the
source fact that justified it, the same way commit `6410935` did. Report: every claim
checked with pass/fail, every fix made, everything you could not verify due to network
access and why, and the exact live URL you'd use to spot-check the deployed result once
this merges and Pages rebuilds.
```

---

## Part 5a — Monetization: build everything that doesn't need the vendor account yet

```
Work in your own worktree: from the repo root run
`git worktree add -b feat/pro-purchase-ui worktrees/pro-purchase-ui main`, and work only
there.

CONTEXT: read `SentryKit/Pro/License.swift`, `LicenseActivation.swift`,
`LicenseProEntitlementStore.swift`, `ProGate.swift`, and `docs/pro-license-dryrun-checklist.md`
in full before writing anything — this task extends a system whose design intent is
stated unusually explicitly in its own doc comments, and duplicating or contradicting
that reasoning is worse than not touching it.

The verification half of Pro licensing is complete: license blobs, Ed25519 signature
checking, entitlement policy, all pure and tested (`SentryTests/LicenseProEntitlementTests.swift`).
What's missing is everything a real human would need to actually buy and activate a
license, and — critically — most of that does NOT require the payment vendor's account
to exist yet, because it's UI and plumbing on this app's side of the seam, not the
vendor's side.

TASK, in order:

1. **A "Buy Sentry Pro" entry point.** Find where `ProUpsellCard.swift` currently
   renders its `unavailableNotice` (the placeholder shown because, per its own doc
   comment, "the purchase path exists it replaces `unavailableNotice` below and nothing
   else on this card changes"). Build the UI half of that replacement now: a button or
   link that opens a checkout URL. Since the real checkout URL doesn't exist yet (Part 0
   item 3), define it as a constant — `SentryKit/Models/AppCredits.swift` is the
   established home for this kind of pinned, single-source URL (follow
   `privacyPolicyURLString`'s exact pattern again) — pointed at a clearly-marked
   placeholder value, and make the button/link only appear when that constant is a real
   URL rather than the placeholder, the same honest-gating pattern
   `UpdateFeedConfiguration.placeholderPublicKey` already uses for the Sparkle key: never
   show a broken purchase button, show nothing (or an honest "not on sale yet" state,
   matching the website's own current wording) until a real value is in place.

2. **An "Enter License Key" activation UI.** `LicenseActivation.swift`'s
   `LicenseActivationClient` protocol defines `activate` and `revalidate` — build the
   Settings-pane UI that calls `activate` with a pasted-in key: a text field, a submit
   action, success/failure states, and wiring into `LicenseProEntitlementStore` so a
   successful activation actually flips the app's entitlement state. This UI can be
   fully built and fully tested right now using a fake/stub conformer of
   `LicenseActivationClient` for tests — do not wait for a real network implementation to
   build and test the UI layer; that's exactly what the protocol seam is for.

3. **Wire `LicenseProEntitlementStore`'s revalidation into the app's existing periodic
   check machinery**, if it isn't already — look at how other periodic background checks
   in this app are scheduled (the Sparkle update check is a reasonable model) and follow
   the same pattern rather than inventing a new scheduling mechanism.

4. **A deactivation/remove-license UI** — the settings pane needs a way to remove an
   activated license (moving to a different Mac, say), not just add one. Check
   `LicenseProEntitlementStore` for whatever "remove" capability already exists at the
   model layer and build the UI for it.

5. **Do NOT write a concrete `LicenseActivationClient` conformer that performs real
   network I/O against any vendor's API.** No vendor has been chosen and no account
   exists (Part 0 item 3); inventing endpoint shapes for a service that doesn't exist
   yet is exactly the "confident-looking code describing a reality that isn't true"
   failure mode `LicenseActivation.swift`'s own doc comment warns against. Build against
   the protocol with a test/stub conformer only. Part 5b picks up the real conformer once
   the vendor is chosen.

6. **Update `docs/pro-license-dryrun-checklist.md`** to reflect that the UI half is now
   real, and clarify exactly what's left for Part 5b to wire up once a vendor exists.

Match `ProUpsellCard.swift`'s existing accessibility care (`.accessibilityElement(children:
.contain)`, the withheld-not-obscured pattern for locked content) in anything new you add
— read that file's full doc comment on why locked rows carry no recoverable text before
building any new locked/gated UI, and apply the same discipline.

`xcodegen generate` then
`xcodebuild -project Sentry.xcodeproj -scheme Sentry -configuration Debug
-derivedDataPath ~/Library/Developer/Sentry-DD-PRO test` must pass, including new tests
for every piece of UI/wiring you add — activation success, activation failure (bad key,
network error, revoked key), deactivation, and the honest-gating behavior of the buy
button against a placeholder vs. real checkout URL. Clean up derived-data when done.

Commit on your branch. Report: exactly what UI you built and where, the stub conformer
you tested against, the placeholder checkout URL you used and how the app behaves before
a real one is set, and a precise, numbered list of what Part 5b needs the moment a vendor
account exists.
```

---

## Part 5b — Monetization: the real checkout (BLOCKED — do not start until Part 0 items 3–4 are done)

```
GATE: do not begin this task until you have been told, explicitly, which payment vendor
was chosen, that the merchant account exists, that a webhook signing secret has been
issued, and that a real production Pro-license Ed25519 keypair has been generated and its
public half given to you. If any of those four things is missing, stop and report which
one — do not proceed with a guess, and do not build against a vendor's API from memory or
assumption; API shapes drift and a wrong guess here is worse than waiting.

Work in your own worktree: from the repo root run
`git worktree add -b feat/pro-checkout-live worktrees/pro-checkout-live main`, and work
only there.

CONTEXT: Part 5a (if it has landed — check `docs/STATUS.md` or `git log` for
`feat/pro-purchase-ui` before starting; if it hasn't landed, do that work first or in
parallel, since this task depends on the UI and protocol scaffolding it builds) built the
UI and the protocol seam. This task fills the seam with a real, working implementation
against the actual chosen vendor, and updates the website with a real checkout link.

TASK:

1. **Implement a concrete `LicenseActivationClient` conformer** against the real vendor's
   API — read their API documentation for the checkout/purchase-lookup and license/entitlement
   endpoints, and implement `activate` and `revalidate` exactly as the protocol in
   `LicenseActivation.swift` specifies. Follow whatever the vendor's SDK or REST API
   requires for auth (API key, likely) — store it the way this codebase already stores
   comparable secrets (check how the notarization credential or any existing API
   credential is handled; likely Keychain-backed at runtime rather than compiled into the
   binary — a webhook secret is different from an API key here, keep them straight).

2. **Wire the real production public key** (`LicenseKeys` — check `License.swift` for the
   exact constant name and where the current build-time value sits, likely a placeholder
   the way `SUPublicEDKey` was before this session's Sparkle work) into `project.yml`, not
   into any generated `Info.plist` directly — follow exactly the precedent set by the
   Sparkle key: a loud, well-commented placeholder becomes the real value in one commit,
   with a test that fails if the placeholder ever comes back. Write that test now, mirroring
   `UpdateFeedConfigurationTests.testHostAppCarriesTheRealSparkleKeysAndIsArmed` from this
   session's Sparkle work as your model.

3. **Update the "Buy Sentry Pro" constant from Part 5a** from its placeholder to the real
   checkout URL the vendor issued.

4. **Build whatever the vendor's checkout flow needs on the website side** — most
   merchant-of-record checkouts (Paddle, Lemon Squeezy) are either a hosted checkout page
   (no website code needed beyond the link) or a small embedded checkout snippet. Follow
   whichever the chosen vendor actually requires; do not build a custom checkout form —
   that is exactly the liability a merchant-of-record exists to take off this project's
   hands, and building around it defeats the purpose of choosing one.

5. **If the vendor's flow requires a webhook receiver** (to mint and email a license the
   moment a purchase completes) — this needs a small always-on server, which this project
   has explicitly avoided everywhere else (the whole product's privacy pitch is "no
   server we run"). Investigate whether the chosen vendor can instead email the license
   key directly via their own post-purchase automation (many can) before building any new
   server component. If a webhook receiver turns out to be unavoidable, stop and report
   this as a genuine architectural decision for Aniketh and Malek — do not silently stand
   up new infrastructure for a product whose core promise is not having any.

6. **Follow `docs/pro-license-dryrun-checklist.md` yourself, in test mode**, end to end:
   a real test-mode purchase, a real activation on a real (non-production) build, a real
   revalidation, and a real revocation disappearing from the app. Do not mark this task
   complete without having actually walked through it once, the way the checklist itself
   demands of a human — if any step in it can only be done by a human with vendor
   dashboard access, stop at that exact step and report precisely what's needed next.

RULES: never let a real vendor secret or the production private signing key exist in the
repository, in a commit, or in test fixtures — only the public key belongs in `project.yml`.
Never bypass or weaken any existing entitlement check to make testing easier; the entire
point of this system is that revocation must actually revoke.

Full test suite must pass, including everything from Part 5a plus new tests for the real
conformer (using recorded/mocked HTTP responses, never live network calls in the test
suite itself — check how existing network-touching code in this repo is tested, likely
`LocalSyncClientTests` or similar, for the established mocking pattern).

Commit on your branch. Report in complete detail: the vendor integration built, the dry
run's actual outcome step by step, the exact production key status, the website checkout
link now live, and an explicit, final statement of whether Sentry Pro can genuinely be
purchased and activated end to end today — this is the one question this entire prompt
document exists to eventually be able to answer "yes" to.
```

---

## Part 6 — App Store Connect screenshot pipeline

```
Work in your own worktree: from the repo root run
`git worktree add -b build/asc-screenshots worktrees/asc-screenshots main`, and work only
there.

CONTEXT: Apple requires App Store screenshots at exact pixel dimensions per device class,
and a bundled Apple Watch app needs its own separate screenshot set. Nothing in this repo
currently produces assets at those exact dimensions. `docs/screenshots/` and
`/Users/malekswilam/Developer/MacStat-Marketing/screenshots-2026-08/` both hold real
screenshots — including Mac ones (`macos-dashboard.png`, `mac-dashboard-dark.png`) — but
those Mac shots are NOT an App Store Connect requirement: this Mac app ships via
Developer ID outside the Mac App Store (confirmed in `scripts/release.sh`'s own header
comment), so it needs no Mac App Store screenshots at all. Do not spend any effort on Mac
screenshot dimensions; only iPhone and Apple Watch need ASC-compliant assets. Check the
existing screenshots' actual pixel dimensions with `sips -g pixelWidth -g pixelHeight
<file>` before assuming any of them happen to already be submission-ready — do not assume
they're wrong either, verify.

CURRENT REQUIREMENTS (confirm these are still current against Apple's published App
Store Connect Help before relying on them — Apple has changed required sizes before,
most recently the "6.9-inch display" class superseding the old "6.5-inch" one; a stale
number here produces rejected uploads):
- iPhone 6.9" display class — required for every app; look up the current exact pixel
  dimensions.
- Apple Watch — required because the app bundles a Watch app (`SentryWatch`). Look up the
  current required sizes for the largest supported Watch case size.

TASK: build a repeatable, scripted capture pipeline — not a one-off manual session —
using `xcrun simctl` to boot the correct simulators at the correct device types, install
the current build, drive it to the states worth showing, and capture screenshots at
exactly the required pixel dimensions. "Repeatable" matters because this needs to re-run
every time the UI changes before a new submission.

STATES TO CAPTURE (use demo/mock data honestly — a screenshot of demo data is fine as
long as it is not presented as if it came from a real connected Mac; check how
`MockDataSource`/`sourceIsDemoData` signals demo state and make sure whatever you
screenshot reads honestly):
- iPhone: Dashboard tab, History tab with a populated chart, Alerts tab, and the
  keep-awake Live Activity if you can trigger and capture it in the simulator (Dynamic
  Island / Lock Screen presentation) — this is newer than the last screenshot set and
  worth showcasing.
- Apple Watch: the Overview page, and the Keep Awake page — precedent already exists in
  `MacStat-Marketing/screenshots-2026-08/` (`watch-overview-68.png`, `watch-keepawake.png`);
  match or improve on it rather than starting blind.
- Capture both light and dark appearance for at least the iPhone Dashboard, matching what
  the existing marketing shots already did (`iphone-dashboard-dark.png` /
  `iphone-dashboard-light.png`).

OUTPUT: a script under `scripts/`, following this repo's convention of documented,
defensive shell scripts (read `scripts/release.sh`'s header style before writing yours —
this repo has strong opinions about failing loud and early) that:
1. Verifies or creates the correct simulators at the exact required device types.
2. Builds and installs current `main` onto them.
3. Drives the app into each state above (check whether `SentryMobile`/`SentryWatch`
   already have XCUITest scaffolding for reaching these states programmatically before
   building your own from scratch).
4. Captures via `xcrun simctl io <device> screenshot`.
5. Verifies each output file's pixel dimensions match the requirement exactly before
   declaring success.
6. Writes to a gitignored directory (e.g. `build/asc-screenshots/iphone-6.9/`,
   `build/asc-screenshots/watch/`), matching how `scripts/release.sh` treats `dist/`.

If any required state cannot be reached without a real paired Mac, say so explicitly
rather than producing a broken or empty screenshot and calling it done.

RULES: do not touch any `.swift` file under `Sentry/`, `SentryKit/`, `SentryMobile/`, or
`SentryWatch/` — if a state genuinely cannot be reached without a small, justified
UI-testing hook, add the absolute minimum and explain exactly why in your report.

Commit the script (not the generated images) on your branch. Report: the exact
dimensions targeted and their source, which states were successfully automated versus
which need a human with a real Mac, and the exact commands to re-run the pipeline from a
clean checkout.
```

---

## Part 7 — Release pipeline dry run (GATED — Part 0 items 1–2 only)

```
GATE: do not begin this task until `security find-identity -v -p codesigning` on the
machine you're working on shows a real "Developer ID Application" identity for team
H7T2D2GL7U, AND a notarization credential has been stored
(`xcrun notarytool store-credentials`). If either is missing, stop immediately and report
which one — do not attempt any part of this task in a degraded or simulated form, and do
not modify `scripts/release.sh` or any release-related file "in preparation."

Work in your own worktree: from the repo root run
`git worktree add -b release/dry-run-v1 worktrees/release-dry-run main`, and work only
there.

CONTEXT: `scripts/release.sh` archives, exports, verifies, packages, notarizes, staples,
and generates a signed Sparkle appcast entry — the whole pipeline — but its own header
comment says plainly that as of when it was written, no step had ever been run end to end
on a machine with real signing certificates. Read that entire header comment before doing
anything. Also read `docs/sparkle-release-signing.md` in full — it documents the exact
signing order (notarize, staple, THEN sign the appcast, never the other order) and why
getting that order wrong invalidates the signature silently.

TASK: run `scripts/release.sh` for real, for the first time, and report exactly what
happens — including everything that goes wrong, since this is explicitly the script's
first real run and its own header comment predicts something will need fixing.

1. Confirm every preflight precondition the script checks is genuinely met before
   running it: the identity (already gated above), `create-dmg` installed, the stored
   notarization credential, and that `project.yml`'s `SUPublicEDKey` is the real key —
   grep for `REPLACE-WITH-YOUR-SPARKLE` and confirm zero matches.
2. Run `scripts/release.sh --skip-notarize` first as a lower-risk dry pass through
   archive/export/verify/package, and inspect the output DMG before committing to a full
   notarization run, which costs real time and, once submitted, cannot be un-submitted.
3. If that looks right, run the full `scripts/release.sh` (no flags) for real.
4. Verify the four bundle Info.plists — the main app, the widget extension, the Watch
   app, and the Watch complication/widget extension — all carry identical
   `CFBundleShortVersionString` and `CFBundleVersion` after archiving. Check all four
   explicitly with `/usr/libexec/PlistBuddy` against the built artifact, not the source
   configuration.
5. Verify the generated appcast entry carries a real `sparkle:edSignature` and that the
   advertised `length` matches the DMG's actual byte size exactly — Sparkle's own tooling
   can silently write an unsigned entry and exit 0 if the signing key doesn't match what
   the app was built with; confirm this did not happen by checking the appcast XML
   directly, not just a clean exit code.
6. Do NOT tag a public release, do NOT push the DMG to GitHub Releases, and do NOT
   publish the new appcast.xml to the `gh-pages` branch. Stop short of every
   externally-visible, hard-to-reverse action — publishing is a decision for Aniketh and
   Malek to make together once they've seen this report.

Note: the current public v1.0 GitHub release has real downloads with the *placeholder*
Sparkle key baked into that specific binary — flag this prominently in your report per
Part 0 item 9; do not act on it yourself.

Report in full detail: every precondition check's result, the `--skip-notarize` dry
pass's output, whether the full run succeeded, the exact verification results from step 4
and 5, any place the script's behavior didn't match its own documentation, any change you
had to make to the script itself (commit those, with a clear explanation), and an
explicit statement of what a human still needs to do to actually publish.
```

---

## Suggested order

Run **Part 1 alone first** — it produces `docs/STATUS.md`, which every subsequent agent
should treat as more current than anything else in `docs/`. Then **Parts 2, 3, 4, 5a, and
6 can all run in parallel**, each in its own worktree, since they touch disjoint files.
**Part 5b** waits on the vendor account (Part 0). **Part 7** waits on the certificate
(Part 0) and should ideally run last, once everything else has landed on `main`, so the
dry run exercises the real, final state of the app rather than a partial one.
