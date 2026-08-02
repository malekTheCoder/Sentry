# Sparkle release procedure — key custody and the signing order

Sentry ships outside the Mac App Store (Developer ID + notarization), so
Sparkle is the **only** update channel an installed copy will ever have. Two
things in this document are irreversible if you get them wrong, and both of
them fail *silently*. Read the whole page once before the first release.

Related code:

- `MacStat/App/UpdateController.swift` — the updater, and its refusal to
  exist when the configuration can't work.
- `MacStatKit/Updates/UpdateFeedConfiguration.swift` — the validation, as
  pure logic (tested in `MacStatTests/UpdateFeedConfigurationTests.swift`).
- `project.yml`, `MacStat` target → `info.properties` — where `SUFeedURL`
  and `SUPublicEDKey` actually live. The checked-in
  `MacStat/Resources/Info.plist` is *generated* by `xcodegen generate`;
  editing it directly does not survive.

---

## 1. The two irreversible things

### `SUFeedURL` is permanent

The feed address is compiled into every shipped binary. An installed Sentry
checks whatever address was baked into the copy the user downloaded — there
is nothing on a server that can redirect it, because the app never asks a
server where to look.

If the feed ever has to move, the only migration path is:

1. Publish one more update **through the old feed** whose payload is a build
   pointing at the new address.
2. Keep the old feed alive indefinitely, for everyone who never installed
   that build.

Current value: `https://malekthecoder.github.io/Sentry/appcast.xml` —
GitHub Pages for `github.com/malekTheCoder/Sentry`. A static file on the same
account that publishes the releases, with no server to run and no certificate
to renew. Pick it once.

### Losing the private EdDSA key orphans every install

Sparkle 2 verifies each update's Ed25519 signature against the public key
baked into the *installed* copy. There is no revocation, no re-key, and no
recovery. If you lose the private half:

- Every existing install refuses every future update, permanently.
- The only fix is asking every user to manually download a new build carrying
  a new public key — and you have no channel through which to ask them,
  because the update channel is the thing that broke.

**Back the private key up before the first release, not after.**

---

## 2. Generating the key pair (you, once, by hand)

This has deliberately not been done for you. The private half is a secret
that must never pass through a build script, a repo, or an assistant.

```sh
# Sparkle's tools ship inside the resolved SPM artifact, so they exist only
# after the project has been built once. $DD is whatever -derivedDataPath
# that build used; every command below assumes it is exported.
export DD="$HOME/Library/Developer/Sentry-Sparkle-DD"

"$DD"/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
# (or use bin/generate_keys from a downloaded Sparkle distribution)
```

It prints the **public** key and stores the **private** key in your login
keychain as `Private key for signing Sparkle updates`.

1. Paste the printed public key into `project.yml` → `MacStat` →
   `info.properties` → `SUPublicEDKey`, replacing
   `REPLACE-WITH-YOUR-SPARKLE-ED25519-PUBLIC-KEY`.
2. Update `UpdateFeedConfiguration.placeholderPublicKey` **only** if you
   change the placeholder string itself — it exists so the app can tell "you
   forgot to replace this" apart from "this key is corrupt," and the two
   strings must stay in sync.
3. Re-run `xcodegen generate`.
4. Export and back up the private key, offline, somewhere you control:

```sh
"$DD"/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key.txt
# Move this file to your password manager / offline backup.
# Do NOT commit it. Do NOT leave it in the working tree.
```

Until step 1 happens, `UpdateFeedConfiguration.availability` resolves to
`.publicKeyPlaceholder`, `UpdateController` constructs no Sparkle object at
all, and Settings ▸ General prints the reason instead of offering a Check for
Updates button. That is intentional: a live button with a placeholder key
would fetch the feed, reject every signature, and report *"You're up to
date!"* — a false statement that stops a user looking for the update they
need.

---

## 3. Release-time order — notarize, staple, THEN sign the appcast

This order is not a style preference. Getting it wrong produces an appcast
that Sparkle rejects with no visible error on the user's Mac.

**The EdDSA signature covers the bytes of the distributed archive.**
`generate_appcast` / `sign_update` hash the DMG (or ZIP) exactly as it exists
on disk at that moment. Notarization stapling *modifies the file* — it writes
the notarization ticket into it. Re-signing the app, re-creating the DMG, or
re-zipping likewise changes the bytes. Any of those, performed **after** the
signature is generated, invalidates it. Sparkle then declines the update, and
because a signature failure is indistinguishable from "nothing new" in the
default UI, the user sees an update that simply never arrives.

Correct order:

```sh
# 0. Bump the version. This is the ONLY place versions are set — Info.plist
#    substitutes $(MARKETING_VERSION)/$(CURRENT_PROJECT_VERSION) from here.
#    project.yml → MacStat → settings → MARKETING_VERSION / CURRENT_PROJECT_VERSION
/opt/homebrew/bin/xcodegen generate

# 1. Build and sign the app with Developer ID, hardened runtime on.
#    Sparkle.framework's nested code must be signed inside-out FIRST.
#    Verified contents of the 2.9.4 XCFramework this project resolves to:
#      Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
#      Sparkle.framework/Versions/B/XPCServices/Installer.xpc
#      Sparkle.framework/Versions/B/Updater.app
#      Sparkle.framework/Versions/B/Autoupdate      (bare executable)
#      Sparkle.framework
#      Sentry.app
#    `codesign --deep` does NOT do this correctly; Apple documents it as
#    unsupported. Xcode's own embed-and-sign phase handles it when the
#    Developer ID identity is configured (that work is tracked separately).

# 2. Package.
hdiutil create -volname Sentry -srcfolder Sentry.app -ov -format UDZO Sentry-<version>.dmg
codesign --sign "Developer ID Application: <NAME> (<TEAMID>)" --timestamp Sentry-<version>.dmg

# 3. Notarize.
xcrun notarytool submit Sentry-<version>.dmg \
  --keychain-profile "<notary-profile>" --wait

# 4. Staple. ← THIS REWRITES THE DMG.
xcrun stapler staple Sentry-<version>.dmg
xcrun stapler validate Sentry-<version>.dmg

# 5. ONLY NOW sign the appcast. Nothing may touch the DMG after this point.
"$DD"/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast /path/to/releases/
#   (reads the private key from your keychain, writes appcast.xml with
#    sparkle:edSignature + length for each archive in that directory)

# 6. Publish appcast.xml AND the DMG to GitHub Pages together. If you
#    re-upload or regenerate the DMG afterwards, go back to step 5.
```

Single-file alternative to step 5, if you maintain `appcast.xml` by hand:

```sh
"$DD"/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update Sentry-<version>.dmg
# prints: sparkle:edSignature="..." length="..."
```

### The `<item>` versions must match the app's Info.plist exactly

Sparkle compares the appcast's `sparkle:shortVersionString` /
`sparkle:version` against the **installed app's** `CFBundleShortVersionString`
/ `CFBundleVersion`. Those two Info.plist keys were hardcoded to `1.0` / `1`
while the build settings said `0.1.0` / `1`; they now substitute
`$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`, so `project.yml` is the
single source of truth. Bump it there and nowhere else. (Left as it was, a
shipped `1.0` build would have considered every `0.x` release in the feed
*older* than itself and installed nothing, forever, with no error.)

---

## 4. Verification checklist before announcing a release

- [ ] `xcrun stapler validate` passes on the exact DMG that is published.
- [ ] `spctl -a -t open --context context:primary-signature -v Sentry-<v>.dmg`
      reports `accepted`.
- [ ] `appcast.xml` `length=` matches the published DMG's byte size exactly
      (a mismatch here is the fastest way to spot a post-signing rewrite).
- [ ] The previous release, freshly installed, actually offers and installs
      this one. Test the *upgrade*, not the download — the download path
      never exercises signature verification.
