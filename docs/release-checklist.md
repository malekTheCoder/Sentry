# Release checklist

Maintainer-facing. The pipeline itself is [`scripts/release.sh`](../scripts/release.sh)
(archive → export → verify → DMG → notarize → staple); its header lists the
one-time prerequisites and it refuses to start until they are present.

Reconciled 2026-09-10 against `main` at `661d2e0`; checked items name their
proof. The one-page view of everything still open is
[`STATUS.md`](STATUS.md).

## One-time, before the first notarized release

- [x] Generate the Sparkle EdDSA key pair and replace the `SUPublicEDKey`
      placeholder in `project.yml` — **done** (`b513558`, generated
      2026-08-13): `project.yml:637` carries a real 32-byte key, not
      `UpdateFeedConfiguration.placeholderPublicKey`. See
      [`sparkle-release-signing.md`](sparkle-release-signing.md).
- [ ] **Back the Sparkle private key up offline.** Cannot be verified from
      the repository — the private half lives only in the generating
      machine's login keychain until someone exports it
      (`generate_keys -x`, procedure in `project.yml`'s comment above the
      key). Losing it permanently orphans every installed copy, with no
      recovery path. *Human — confirm it is exported and stored.*
- [x] Create a **Developer ID Application** certificate for team
      `H7T2D2GL7U` — **present on this machine** as of 2026-09-10:
      `security find-identity -v -p codesigning` lists
      `"Developer ID Application: Aniketh Bandlamudi (H7T2D2GL7U)"`.
- [ ] Verify the Release signing configuration end to end under that
      identity — not yet done; `scripts/release.sh` has never completed a
      run. Blocked on the notarization credential below.
- [ ] Store a notarization credential:
      `xcrun notarytool store-credentials AC_NOTARY …` (exact invocation in
      the `release.sh` header). **Not done** — verified 2026-09-10:
      `xcrun notarytool history --keychain-profile AC_NOTARY` reports "No
      Keychain password item found for profile: AC_NOTARY". *Human — needs
      the App Store Connect app-specific password.*
- [x] Publish `appcast.xml` at the feed URL compiled into the app
      (`https://malekthecoder.github.io/Sentry/appcast.xml`) — **live**
      (HTTP 200, re-verified 2026-09-10), served from the `gh-pages` branch
      (`ffe7e7c`). The channel is deliberately empty until `release.sh`
      appends a signed entry. That URL is baked into every shipped binary
      and cannot be changed on copies already installed — the repo and
      account names are now effectively frozen.
- [ ] Verify the SMAppService / command-line-bridge flow end to end under a
      Developer ID signature — it is implemented and merged, but has only
      run under ad-hoc / Apple Development signatures so far. Blocked on
      the first Developer ID build.
- [x] Publish [`privacy-policy.md`](privacy-policy.md) at a public HTTPS
      URL — **live** at `https://malekthecoder.github.io/Sentry/privacy-policy`
      (HTTP 200, re-verified 2026-09-10) from `gh-pages`, with the
      effective date and the `getsentryapp@gmail.com` contact filled in
      (`4deba60`). The Mac and iPhone About screens link to it. Note the
      copies on `main` (`docs/privacy-policy.md`, `docs/pages-site/`)
      have drifted behind the published one — see `STATUS.md`.

## Every release

- [ ] Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in
      `project.yml`.
- [ ] Full test suite green on macOS; iOS and watchOS targets build.
- [ ] `scripts/release.sh` — end to end, including notarization and the
      final `spctl -a -vvv -t install` Gatekeeper assessment.
- [ ] Tag `vX.Y.Z`, create the GitHub release, and attach `Sentry.dmg` with
      its SHA-256 checksum in the notes. The README's download button points
      at `releases/latest/download/Sentry.dmg`, so the asset must keep
      exactly that name.
- [ ] Update and publish `appcast.xml` so installed copies see the update.

## Known open questions

- The name "Sentry" collides with Sentry.io (application monitoring — the
  same developer-tools audience the agent-manager features target). Renaming
  is cheap until the first Sparkle feed is published and the App IDs are
  registered, and effectively permanent after. **The feed is now
  published** (see above), which narrows the window: the feed *URL* is
  frozen, but a rename of the product could still ship as long as the
  GitHub account and repo path stay put.
- **The public `v1.0` GitHub release predates this checklist.** Tag `v1.0`
  (`cb0e992`, 2026-08-09; release published 2026-08-08 with `Sentry.dmg`
  attached) was cut *before* the real Sparkle key (`b513558`, 2026-08-13)
  and before any notarization credential existed, so those binaries carry
  the placeholder `SUPublicEDKey` and can never auto-update — Sparkle
  rejects every signed entry under a key they don't hold. Nothing in the
  release pipeline can fix installed copies; the options are a manual
  re-download notice, a fresh `v1.0.x` release that the README's
  `releases/latest` link picks up, or leaving it. *Human decision;*
  tracked in `STATUS.md`.
