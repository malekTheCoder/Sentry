# Release checklist

Maintainer-facing. The pipeline itself is [`scripts/release.sh`](../scripts/release.sh)
(archive → export → verify → DMG → notarize → staple); its header lists the
one-time prerequisites and it refuses to start until they are present.

## One-time, before the first notarized release

- [ ] Generate the Sparkle EdDSA key pair and replace the `SUPublicEDKey`
      placeholder in `project.yml` — see
      [`sparkle-release-signing.md`](sparkle-release-signing.md).
      **Back the private key up offline**: losing it permanently orphans
      every installed copy, with no recovery path.
- [ ] Create a **Developer ID Application** certificate for team
      `H7T2D2GL7U` and verify the Release signing configuration end to end.
- [ ] Store a notarization credential:
      `xcrun notarytool store-credentials AC_NOTARY …` (exact invocation in
      the `release.sh` header).
- [ ] Publish `appcast.xml` at the feed URL compiled into the app
      (`https://malekthecoder.github.io/Sentry/appcast.xml`). That URL is
      baked into every shipped binary and cannot be changed on copies
      already installed — if the GitHub account or repo is ever going to be
      renamed, do it *before* the first release, never after.
- [ ] Verify the SMAppService / command-line-bridge flow end to end under a
      Developer ID signature — it is implemented and merged, but has only
      run under ad-hoc / Apple Development signatures so far.
- [ ] Publish [`privacy-policy.md`](privacy-policy.md) at a public HTTPS
      URL — see [`privacy-policy-publishing.md`](privacy-policy-publishing.md).
      The Mac and iPhone About screens link to it.

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
  registered, and effectively permanent after.
