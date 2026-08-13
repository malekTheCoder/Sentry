#!/bin/zsh
# Build, sign, notarize and staple a distributable Sentry.dmg.
#
# Sentry ships Developer ID + notarization, outside the Mac App Store. That is
# not a preference: the app reads `libIOReport.dylib` and the private
# `IOHIDEventSystemClient` API through dlopen, and neither exists inside the App
# Sandbox, which the App Store requires. See Sentry/Sentry.entitlements and
# plan §14.1.
#
# ─── HONESTY NOTE, READ THIS FIRST ───────────────────────────────────────────
# As of the commit that added this script, no step below has ever been executed
# end to end. The machine it was written on has zero code-signing identities
# (`security find-identity -v -p codesigning` → "0 valid identities found"), so
# `xcodebuild archive` cannot get past the signing step, and everything after it
# is unreachable. What *is* verified is that the Debug build and the full test
# suite still pass unchanged with the Release signing configuration in place.
#
# So: treat this script as a carefully written first attempt, not a proven
# pipeline. It is deliberately built to fail early and loudly — `preflight`
# below refuses to start until every prerequisite is actually present — rather
# than to grind through five minutes of archiving and then die somewhere
# confusing. The first person to run it with real certificates should expect to
# fix something, and should fix it here rather than working around it by hand.
# ─────────────────────────────────────────────────────────────────────────────
#
# WHAT YOU NEED, ONCE
#
#   1. Apple Developer Program membership (team H7T2D2GL7U) and a
#      `Developer ID Application` certificate installed in the login keychain.
#      A `Developer ID Installer` certificate is NOT needed — that is for .pkg;
#      a .dmg does not use it.
#
#   2. `brew install create-dmg`
#
#   3. A stored notarization credential, so no password is ever typed into (or
#      read by) this script:
#
#        xcrun notarytool store-credentials "AC_NOTARY" \
#          --apple-id "you@example.com" \
#          --team-id H7T2D2GL7U \
#          --password "<app-specific-password from appleid.apple.com>"
#
#      `altool` is not an alternative. Apple stopped accepting altool
#      submissions in November 2023; anything on the internet telling you to run
#      `xcrun altool --notarize-app` is describing a dead API.
#
# USAGE
#
#   scripts/release.sh                 # archive → export → verify → dmg → notarize → staple
#   scripts/release.sh --resign        # additionally re-sign nested code inner-out (see below)
#   scripts/release.sh --skip-notarize # everything up to (not including) submission
#
# Environment overrides: NOTARY_PROFILE (default AC_NOTARY), BUILD_DIR (default
# ./build), DEVELOPER_DIR (auto-detected below).

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

# ── Configuration ────────────────────────────────────────────────────────────

TEAM_ID="H7T2D2GL7U"
IDENTITY="Developer ID Application"
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_NOTARY}"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
ARCHIVE="$BUILD_DIR/Sentry.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/Sentry.app"
DMG="$BUILD_DIR/Sentry.dmg"

RESIGN=0
SKIP_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --resign) RESIGN=1 ;;
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# `xcode-select` on this machine points at /Library/Developer/CommandLineTools,
# which has no xcodebuild — the same quirk run.sh documents and works around.
# Prefer whatever the caller set, then a released Xcode, then a beta.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [[ -d "$candidate/Contents/Developer" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi

say() { printf '\n▶ %s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

# ── 0. Preflight ─────────────────────────────────────────────────────────────
#
# Every check here exists because the failure it prevents is expensive or
# confusing. A missing certificate surfaces as an xcodebuild error 20 pages into
# a log; a missing notarytool profile surfaces only after the archive, export
# and DMG steps have already burned several minutes.

preflight() {
  say "Preflight"

  [[ -n "${DEVELOPER_DIR:-}" ]] || die "No Xcode found. Install Xcode or set DEVELOPER_DIR."
  [[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]] || die "DEVELOPER_DIR=$DEVELOPER_DIR has no xcodebuild."

  command -v /opt/homebrew/bin/xcodegen >/dev/null || die "xcodegen missing: brew install xcodegen"
  command -v create-dmg >/dev/null || die "create-dmg missing: brew install create-dmg"

  # `-v` lists only valid (unexpired, with-private-key) identities, which is
  # exactly the question worth asking.
  if ! security find-identity -v -p codesigning | grep -q "$IDENTITY: "; then
    print -r -- "✗ No '$IDENTITY' identity in any keychain." >&2
    print -r -- "  Current codesigning identities:" >&2
    security find-identity -v -p codesigning >&2
    print -r -- "  Create one at https://developer.apple.com/account/resources/certificates" >&2
    print -r -- "  (Certificates → + → Developer ID Application), download it, and open it." >&2
    exit 1
  fi

  if (( ! SKIP_NOTARIZE )); then
    # There is no `notarytool list-credentials`; the cheapest real check is a
    # request that needs the stored credential and returns fast. No `--limit`:
    # Xcode 26 beta's notarytool doesn't have the flag (observed 2026-08-08),
    # and plain `history` is just as fast a validity probe.
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
      die "notarytool profile '$NOTARY_PROFILE' is missing or invalid. See the header of this script for 'notarytool store-credentials'."
    fi
  fi

  # A release built while SUPublicEDKey is still the placeholder ships with a
  # dead updater — Sparkle can never verify an update it downloads, and v1.0
  # proved this script will happily notarize such a build. project.yml is the
  # exact value the built Info.plist will carry (archive() regenerates the
  # project from it), so failing here costs seconds instead of a full
  # archive+notarize cycle. The placeholder string is defined in
  # SentryKit/Updates/UpdateFeedConfiguration.swift (placeholderPublicKey) and
  # is deliberately non-base64 so this exact-match grep can't false-positive.
  if grep -q 'SUPublicEDKey: "REPLACE-WITH-YOUR-SPARKLE-ED25519-PUBLIC-KEY"' project.yml; then
    die "SUPublicEDKey in project.yml is still the placeholder — this build's updater would be permanently dead. Embed the real Sparkle public key (task B1) before cutting a release."
  fi

  # Derived data and build output must live outside the repo when the repo sits
  # in an iCloud/FileProvider-synced directory: sync stamps com.apple.FinderInfo
  # xattrs onto build products and codesign then rejects them with "resource
  # fork, Finder information, or similar detritus not allowed". run.sh documents
  # the same hazard for its DerivedData path. BUILD_DIR is under the repo by
  # default because it is gitignored and short-lived — if this machine's repo is
  # ever back under ~/Documents, set BUILD_DIR somewhere under ~/Library.
  print -r -- "  Xcode:      $DEVELOPER_DIR"
  print -r -- "  Identity:   $IDENTITY ($TEAM_ID)"
  print -r -- "  Build dir:  $BUILD_DIR"
}

# ── 1. Archive ───────────────────────────────────────────────────────────────
#
# The Sentry scheme builds Sentry, SentryMCP and SentryCLI; the two tools
# are copied into Sentry.app/Contents/MacOS by the app target's "Embed
# Dependencies" phase (see project.yml), so the archive contains one bundle with
# all of it inside. `-configuration Release` is what selects the
# `DeveloperIDSigned` settings: real identity, hardened runtime, secure
# timestamp, no get-task-allow.

archive() {
  say "Archiving (Release)"
  /opt/homebrew/bin/xcodegen generate
  rm -rf "$ARCHIVE"
  mkdir -p "$BUILD_DIR"
  xcodebuild -project Sentry.xcodeproj \
             -scheme Sentry \
             -configuration Release \
             -destination 'generic/platform=macOS' \
             -archivePath "$ARCHIVE" \
             archive
}

# ── 2. Export ────────────────────────────────────────────────────────────────

export_archive() {
  say "Exporting"
  rm -rf "$EXPORT_DIR"
  # Xcode 26 beta's exportArchive rejects `method: developer-id`
  # ("expected one {} but found developer-id", observed 2026-08-08). The
  # archive's app is already fully signed by the archive step's manual
  # Developer ID settings, so falling back to copying it out of the archive
  # loses nothing — `verify` below still gates on every signature property
  # notarization checks.
  if ! xcodebuild -exportArchive \
                  -archivePath "$ARCHIVE" \
                  -exportOptionsPlist "$REPO_ROOT/ExportOptions.plist" \
                  -exportPath "$EXPORT_DIR"; then
    print -r -- "  exportArchive failed; copying the signed app out of the archive instead."
    mkdir -p "$EXPORT_DIR"
    cp -R "$ARCHIVE/Products/Applications/Sentry.app" "$EXPORT_DIR/"
  fi
  [[ -d "$APP" ]] || die "Export produced no Sentry.app at $APP"
}

# ── 3. Sign inner-out (opt-in) ───────────────────────────────────────────────
#
# Nested code must be signed before its container: a signature seals a hash of
# everything inside it, so re-signing a framework after the app invalidates the
# app. Order is frameworks → nested executables → appex → app bundle.
#
# This is OFF by default, and that is the considered choice. `xcodebuild
# archive` already signs in exactly this order using the per-target settings in
# project.yml, and blindly re-signing on top of a correct signature is a common
# way to *break* one — it is easy to drop `--options runtime`, lose the
# entitlements, or re-sign a framework and forget to re-seal the app.
#
# Use --resign when you have modified the exported bundle after export (added a
# binary, stripped something, patched an Info.plist), which is the only
# situation where the archive's signatures are genuinely stale. `verify` below
# runs either way and is what actually tells you whether the bundle is
# shippable.

sign_inner_out() {
  say "Re-signing inner-out"
  local flags=(--force --timestamp --options runtime --sign "$IDENTITY")

  # Sparkle's nested helpers first — deeper than the framework that contains
  # them, and the first real notarization run (2026-08-08) proved they are
  # rejected if they keep Sparkle's upstream signature: "not signed with a
  # valid Developer ID certificate" / "no secure timestamp" on Updater.app,
  # Autoupdate, and both XPC services. A flat `codesign` on the .framework
  # does NOT recurse into these. The XPC services keep their own sandbox
  # entitlements via --preserve-metadata.
  local sparkle="$APP/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$sparkle" ]]; then
    local nested
    for nested in "$sparkle"/Versions/B/XPCServices/*.xpc(N); do
      print -r -- "  sparkle xpc: ${nested:t}"
      codesign "${flags[@]}" --preserve-metadata=entitlements "$nested"
    done
    for nested in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app"; do
      [[ -e "$nested" ]] || continue
      print -r -- "  sparkle helper: ${nested:t}"
      codesign "${flags[@]}" "$nested"
    done
  fi

  # Frameworks next (deepest sealed containers after Sparkle's innards).
  local fw
  for fw in "$APP"/Contents/Frameworks/*.framework(N); do
    print -r -- "  framework: ${fw:t}"
    codesign "${flags[@]}" "$fw"
  done

  # Then the loose nested executables (sentry, SentryMCP) — everything in
  # Contents/MacOS that is a Mach-O and is not the app's own main binary, which
  # is sealed last as part of the bundle.
  local exe
  for exe in "$APP"/Contents/MacOS/*(N); do
    [[ "${exe:t}" == "Sentry" ]] && continue
    file "$exe" | grep -q "Mach-O" || continue
    print -r -- "  executable: ${exe:t}"
    codesign "${flags[@]}" "$exe"
  done

  # Then app extensions.
  local ax
  for ax in "$APP"/Contents/PlugIns/*.appex(N); do
    print -r -- "  appex: ${ax:t}"
    codesign "${flags[@]}" "$ax"
  done

  # Finally the app itself, with its entitlements. This is the only signature
  # that carries com.apple.security.app-sandbox = false.
  print -r -- "  app: ${APP:t}"
  codesign "${flags[@]}" --entitlements "$REPO_ROOT/Sentry/Sentry.entitlements" "$APP"
}

# ── 4. Verify before submitting ──────────────────────────────────────────────
#
# Every check here maps to a notarization rejection listed in plan §15.2. The
# point is to learn about them in seconds locally rather than in minutes from
# Apple's notary service, whose error messages name the file but rarely the fix.

verify() {
  say "Verifying signatures"

  # Whole-bundle structural check: catches an unsigned nested binary, a
  # modified-after-signing resource, and a broken seal.
  codesign --verify --deep --strict --verbose=2 "$APP"

  # Per-Mach-O checks. `--deep` above does not tell you whether each nested
  # binary carries the hardened runtime flag, and a single one without it fails
  # the whole submission.
  local target failures=0
  local -a targets
  targets=("$APP")
  targets+=("$APP"/Contents/Frameworks/*.framework(N))
  targets+=("$APP"/Contents/PlugIns/*.appex(N))
  local exe
  for exe in "$APP"/Contents/MacOS/*(N); do
    [[ "${exe:t}" == "Sentry" ]] && continue
    file "$exe" | grep -q "Mach-O" && targets+=("$exe")
  done

  for target in "${targets[@]}"; do
    local info
    info="$(codesign -dv --verbose=4 "$target" 2>&1)"

    if ! print -r -- "$info" | grep -q "runtime"; then
      print -r -- "✗ no hardened runtime: $target" >&2
      (( failures++ ))
    fi
    if ! print -r -- "$info" | grep -q "TeamIdentifier=$TEAM_ID"; then
      print -r -- "✗ wrong or missing Team ID: $target" >&2
      (( failures++ ))
    fi
    if ! print -r -- "$info" | grep -q "Timestamp="; then
      print -r -- "✗ no secure timestamp: $target" >&2
      (( failures++ ))
    fi
  done

  # get-task-allow in a Release build is an automatic rejection. project.yml
  # sets CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO for Release specifically to
  # prevent this; the check is here because "specifically to prevent this" is a
  # claim worth testing rather than trusting.
  if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "get-task-allow"; then
    print -r -- "✗ com.apple.security.get-task-allow present in the Release app" >&2
    (( failures++ ))
  fi

  # Belt-and-braces twin of the preflight placeholder check: verify the key
  # that actually shipped inside the exported app, in case the plist was
  # produced by something other than this run's xcodegen pass.
  local built_key
  built_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -z "$built_key" || "$built_key" == "REPLACE-WITH-YOUR-SPARKLE-ED25519-PUBLIC-KEY" ]]; then
    print -r -- "✗ built Info.plist has no real SUPublicEDKey (found: '${built_key:-<missing>}') — updater would be dead" >&2
    (( failures++ ))
  fi

  (( failures == 0 )) || die "$failures signature problem(s); not submitting."
  print -r -- "  All nested code: hardened runtime + $TEAM_ID + secure timestamp."
}

# ── 5. Package ───────────────────────────────────────────────────────────────
#
# The DMG is signed too. Stapling attaches the notarization ticket to the DMG,
# and Gatekeeper is happier validating a signed container; an unsigned DMG can
# still be stapled but gives the user a worse first-launch experience.

package() {
  say "Building DMG"
  rm -f "$DMG"
  create-dmg \
    --volname "Sentry" \
    --background "$REPO_ROOT/scripts/dmg-background.png" \
    --window-size 800 400 \
    --icon-size 128 \
    --icon "Sentry.app" 200 185 \
    --app-drop-link 600 185 \
    "$DMG" \
    "$EXPORT_DIR"
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
}

# ── 6. Notarize, staple, and check what a user's Mac will check ──────────────

notarize() {
  say "Submitting to the notary service (this waits; typically 1-15 minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

  say "Stapling"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"

  # `spctl -a -t install` is the assessment a Mac actually performs when the
  # user opens the DMG. It is the only step here that answers "will this launch
  # on someone else's machine" rather than "did the tooling succeed".
  say "Gatekeeper assessment"
  spctl -a -vvv -t install "$DMG"
}

# ── Run ──────────────────────────────────────────────────────────────────────

preflight
archive
export_archive
(( RESIGN )) && sign_inner_out
verify
package

if (( SKIP_NOTARIZE )); then
  say "Done (--skip-notarize). Unnotarized DMG at $DMG"
  print -r -- "  It will NOT open cleanly on another Mac until it is notarized and stapled."
  exit 0
fi

notarize

say "Done"
print -r -- "  $DMG — signed, notarized, stapled, Gatekeeper-approved."
