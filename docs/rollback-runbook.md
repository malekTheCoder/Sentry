# Rollback runbook

What to do when a shipped Mac release turns out to be bad — crashing,
corrupting data, or misbehaving badly enough that users should get off it.
Read this once before you ever need it: the constraints in §1 are why the
procedure looks the way it does, and two of them are easy to get wrong
under pressure.

Related documents:

- [`scripts/release.sh`](../scripts/release.sh) — the build pipeline
  (archive → export → verify → DMG → notarize → staple).
- [`sparkle-release-signing.md`](sparkle-release-signing.md) — key custody
  and the staple-then-sign order. §3 there is load-bearing for this page.
- [`release-checklist.md`](release-checklist.md) — the per-release steps a
  rollback release must also complete.

---

## 1. Facts that shape the procedure

**Sparkle never downgrades.** An installed copy compares each appcast
item's `sparkle:shortVersionString` / `sparkle:version` against its own
`CFBundleShortVersionString` / `CFBundleVersion` and only offers strictly
newer versions. There is no mechanism to move a user from 1.2.0 "back" to
1.1.0 as 1.1.0. A rollback is therefore always a **re-release**: the
last-good code, shipped again under a *higher* version number, through the
same pipeline as any other release.

**There is zero telemetry.** No crash reporting, no analytics, no phone
home of any kind. You learn that a release is bad from GitHub Issues, or
not at all. Assume the reports you see are a fraction of the users
affected, and that you have no way to count or contact the rest.

**The appcast is the only channel to an installed copy.** Every shipped
binary has `https://malekthecoder.github.io/Sentry/appcast.xml` compiled in
as `SUFeedURL` (set in `project.yml`; see
`SentryKit/Updates/UpdateFeedConfiguration.swift`). Removing the bad item
from that file protects exactly one group: users who have **not yet
updated**. Everyone who already installed the bad build stays on it until
a newer version appears in the feed. Pulling the item is damage control,
never the fix.

**Released DMGs are permanent.** Every published DMG stays attached to its
GitHub release forever. Do not delete a bad release or its asset: the
SHA-256 checksum in its notes is how a user — or you — identifies exactly
which bytes are installed, and history that disappears can't be audited.

**The rollback build goes through the full pipeline.** The EdDSA signature
covers the exact bytes of the stapled DMG, and stapling rewrites the file
(`sparkle-release-signing.md` §3). So there is no shortcut where you reuse
the old DMG or the old signature under a new version number. A rollback
release is mechanically identical to a normal release: archive, notarize,
staple, *then* a human runs `sign_update`, *then* the appcast is edited.

---

## 2. Roll back or hotfix forward?

Either way you are shipping a new, higher-versioned release through the
full pipeline. The only question is what code goes in it.

| Situation | Do |
| --- | --- |
| Cause understood; fix is small and testable quickly | Hotfix forward |
| Cause unknown, or the fix is non-trivial | Roll back to last good |
| The release corrupts user data, or leaves an orphaned background helper registered | Roll back now, investigate afterwards |
| The release introduced a security regression | Roll back now (and handle per [`SECURITY.md`](../SECURITY.md)) |
| Last-good contains the vulnerability the bad release fixed | Hotfix forward — never re-ship a known vulnerability |
| The bad release added a database migration | Prefer hotfix forward: last-good code may not open a `history.sqlite` the bad release already migrated. If you must roll back, verify last-good against a migrated database first. |

When in doubt, roll back. Code that ran quietly in the field for weeks is
a safer thing to ship than a fix written at midnight.

---

## 3. Procedure

### Step 0 — stop the spread (minutes, do this first)

1. **Pull the bad item from the appcast.** Edit `appcast.xml` on the
   GitHub Pages site that serves
   `https://malekthecoder.github.io/Sentry/appcast.xml`, delete the bad
   release's `<item>`, and publish. Installed copies check the feed about
   once a day, so this takes effect over the following day.
2. **Repoint new downloads.** On GitHub, mark the bad release as a
   **pre-release**. The README's download button resolves
   `releases/latest/download/Sentry.dmg` to the newest non-prerelease, so
   this makes new downloads serve the last good build again. Do **not**
   delete the release or its DMG (see §1).
3. **Warn in the notes.** Edit the bad release's notes: state the problem
   in the first line, and say a fixed version will arrive via the in-app
   updater.

Be clear-eyed about what this step accomplished: nobody who already
installed the bad build has been helped yet. Everything below exists for
them.

### Step 1 — choose the payload

- Rolling back: check out the last-good release tag.
- Hotfixing: branch from the last-good tag and apply the minimal fix.

### Step 2 — bump the version HIGHER than the bad release

In `project.yml`, raise both `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` above the bad release's values — this is the
only place versions are set; Info.plist substitutes them, and Sparkle
compares them. Example: bad release `1.2.0` (build 12) → rollback ships as
`1.2.1` (build 13), even though its code is `1.1.x`'s. Then:

```sh
/opt/homebrew/bin/xcodegen generate
```

If you reuse or lower either number, every installed copy of the bad
build considers the rollback *older* and installs nothing, with no error.

### Step 3 — build, notarize, staple

```sh
scripts/release.sh
```

Archive → export → verify → DMG → notarize → staple, with the same gates
as any release. Do not skip the final `spctl` assessment; a rollback that
Gatekeeper blocks is worse than the problem it fixes.

### Step 4 — sign the update (a human, by hand)

Run Sparkle's `sign_update` against the stapled DMG:

```sh
# $DD = the DerivedData path the build used; see sparkle-release-signing.md §2
"$DD"/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update build/Sentry.dmg
# prints: sparkle:edSignature="..." length="..."
```

This reads the private EdDSA key from your login keychain — it is a step a
person runs, never a script in this repo. Order matters: staple first,
sign second, and **nothing may touch the DMG after this point**. If
anything rewrites the DMG, go back to step 3's stapling and re-sign.

### Step 5 — publish

1. Tag `vX.Y.Z` and create the GitHub release. Attach the DMG under the
   exact name `Sentry.dmg` (the README's download link depends on it) with
   its SHA-256 checksum in the notes. Say plainly what this release is:
   "re-issue of X.Y.W to withdraw X.Y.Z-bad" or "hotfix for …".
2. Add the new `<item>` to `appcast.xml` — version numbers from step 2,
   `sparkle:edSignature` and `length` from step 4 — and publish it to the
   Pages site. The enclosure URL must name the *versioned* release asset
   (`…/releases/download/vX.Y.Z/Sentry.dmg`), never
   `releases/latest/…`: the signature covers specific bytes, and a URL
   whose bytes change with each release can never verify.
3. Confirm the appcast's `length` equals the published DMG's byte count
   exactly. A mismatch is the fastest tell that something rewrote the file
   after signing.

### Step 6 — verify the escape path actually works

From the checklist in `sparkle-release-signing.md` §4, plus the one check
that is the entire point of this release:

- [ ] `xcrun stapler validate` passes on the exact published DMG.
- [ ] `spctl -a -t open --context context:primary-signature -v` reports
      `accepted`.
- [ ] **Install the BAD version fresh, run it, and confirm it offers and
      installs this release.** Test the upgrade, not the download — the
      download path never exercises signature verification, and a
      signature failure looks exactly like "no updates available."

### Step 7 — afterwards

- Leave the bad release marked pre-release, with the warning in its notes.
- Open or update a tracking issue: affected version range, symptoms, and
  whether the remedy was a rollback or a fix.
- If you rolled back, the withdrawn changes still need to ship eventually —
  reopen whatever tracked them, and write down what the re-release must
  prove before it goes out again.
