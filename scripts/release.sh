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
#   scripts/release.sh                 # archive → export → verify → dmg → notarize → staple → appcast
#   scripts/release.sh --resign        # additionally re-sign nested code inner-out (see below)
#   scripts/release.sh --skip-notarize # everything up to (not including) submission
#
# `--skip-notarize` also skips the appcast: signing an unstapled DMG would
# produce a feed entry whose signature stops matching the moment the DMG is
# stapled for real. There is deliberately no way to generate a feed for a
# build that has not been through the notary.
#
# Environment overrides: NOTARY_PROFILE (default AC_NOTARY), BUILD_DIR (default
# ./build), RELEASES_DIR (default ./dist), SPARKLE_BIN_DIR (default: found
# under DerivedData), DEVELOPER_DIR (auto-detected below).

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

  # The appcast is generated at the very end of a run that may have already
  # spent fifteen minutes in the notary queue, and it needs two things this
  # machine may simply not have: Sparkle's tool, and the private key whose
  # public half is compiled into the app. Checking both here turns "the
  # release finished but produced no feed" into a five-second failure.
  if (( ! SKIP_NOTARIZE )); then
    local tool
    tool="$(find_sparkle_tool generate_appcast)"
    [[ -x "$tool" ]] || die "generate_appcast not found. Build once so SPM resolves Sparkle, or set SPARKLE_BIN_DIR."

    # The key is stored as a generic password by generate_keys. Absence here
    # means whoever is cutting this release does not hold the private half,
    # and nothing they sign would be accepted by an installed copy.
    if ! security find-generic-password -s "https://sparkle-project.org" >/dev/null 2>&1; then
      die "No Sparkle private key in this keychain. Only the machine that ran generate_keys can sign updates; import the backed-up key before cutting a release."
    fi
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

# ── 7. Appcast ───────────────────────────────────────────────────────────────
#
# The step that turns a notarized DMG into an update an installed copy will
# actually accept.
#
# ORDER IS LOAD-BEARING: THIS RUNS AFTER STAPLING, NEVER BEFORE.
# `xcrun stapler staple` rewrites the DMG in place to embed the notarization
# ticket. A signature taken before that describes a file that no longer
# exists, and Sparkle rejects the download with a signature mismatch — on the
# user's machine, silently, long after the release looked successful here.
# Everything below therefore lives after notarize() in the run order, and
# nothing may touch the DMG once this function has run.
#
# WHY THE PUBLISHED FEED IS FETCHED FIRST. generate_appcast reuses an
# appcast.xml already present in the archives directory and adds new entries
# to it (`--help`: "that file will be re-used and updated with new entries").
# The live feed is the only authoritative copy of what users have been offered
# so far, so it is pulled down rather than reconstructed from whatever happens
# to be in a local directory. Generating from an empty directory would publish
# a feed containing only this release, which is survivable but throws away
# every previous entry's release notes and signatures for no reason.
#
# WHY --download-url-prefix IS COMPUTED PER RELEASE. The DMGs live on GitHub
# Releases, whose download URLs embed the tag (…/releases/download/v1.1/…), so
# the prefix differs for every version. generate_appcast applies the prefix
# only to entries it adds, leaving previously generated URLs untouched, which
# is exactly the behaviour this needs.

RELEASES_DIR="${RELEASES_DIR:-$REPO_ROOT/dist}"
FEED_URL="https://malekthecoder.github.io/Sentry/appcast.xml"
RELEASE_URL_BASE="https://github.com/malekTheCoder/Sentry/releases/download"

# Sparkle's tools ship inside the resolved SPM artifact, so they exist only
# after the project has been built at least once, and the path contains a
# per-checkout hash. Prefer an explicit override, then anything on PATH, then
# the newest copy under DerivedData.
find_sparkle_tool() {
  local tool="$1"
  if [[ -n "${SPARKLE_BIN_DIR:-}" ]]; then
    print -r -- "$SPARKLE_BIN_DIR/$tool"; return
  fi
  if command -v "$tool" >/dev/null 2>&1; then
    command -v "$tool"; return
  fi
  local found
  found="$(find ~/Library/Developer/Xcode/DerivedData \
             -path "*/artifacts/sparkle/Sparkle/bin/$tool" -type f 2>/dev/null \
           | head -1)"
  print -r -- "$found"
}

appcast() {
  say "Generating the Sparkle appcast"

  local generate_appcast version dmg_name staged
  generate_appcast="$(find_sparkle_tool generate_appcast)"
  [[ -x "$generate_appcast" ]] || die "generate_appcast not found. Build once so SPM resolves Sparkle, or set SPARKLE_BIN_DIR."

  # The version the *built app* carries, not what project.yml says now — the
  # appcast's version must match the bundle byte for byte or Sparkle will
  # compare wrongly and offer nothing.
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  [[ -n "$version" ]] || die "could not read CFBundleShortVersionString from the built app"

  # A versioned filename, because every GitHub release asset needs a distinct
  # name and because a user who downloads two of these should be able to tell
  # them apart. Renaming is safe here: the notarization ticket lives inside
  # the DMG, not in its name or path.
  dmg_name="Sentry-$version.dmg"
  mkdir -p "$RELEASES_DIR"
  staged="$RELEASES_DIR/$dmg_name"
  cp "$DMG" "$staged"

  # Pull the published feed so previous entries survive. A 404 is the expected
  # answer for the very first release and must not abort the run; anything
  # else that leaves a non-XML body (a proxy error page, say) would be worse
  # than starting fresh, so the result is sanity-checked before being kept.
  if curl -fsSL "$FEED_URL" -o "$RELEASES_DIR/appcast.xml" 2>/dev/null; then
    if grep -q "<rss" "$RELEASES_DIR/appcast.xml"; then
      print -r -- "  Fetched the live feed; new entry will be appended to it."
    else
      print -r -- "  ⚠ $FEED_URL did not return an RSS document — starting a fresh feed."
      rm -f "$RELEASES_DIR/appcast.xml"
    fi
  else
    print -r -- "  No published feed yet (first release) — generating a new one."
  fi

  "$generate_appcast" \
    --download-url-prefix "$RELEASE_URL_BASE/v$version/" \
    --link "https://malekthecoder.github.io/Sentry/" \
    "$RELEASES_DIR"

  # ── The feed must actually be signed ──────────────────────────────────────
  #
  # generate_appcast will happily emit an entry with NO sparkle:edSignature,
  # print "Wrote 1 new update", and exit 0. Observed directly: run against a
  # correctly signed, notarized app whose SUPublicEDKey does not match the
  # private key in the keychain, it writes an unsigned enclosure and says
  # nothing — not even with --verbose. An installed Sentry rejects an unsigned
  # update, so the result is a release that looks perfect here and silently
  # fails to install for every user.
  #
  # Nothing else in this script catches it. The preflight and verify checks
  # confirm the app carries a real, non-placeholder key; this confirms that
  # the key is the one whose private half just signed the feed, which is a
  # different claim and the one that actually matters.
  if ! grep -q 'sparkle:edSignature="' "$RELEASES_DIR/appcast.xml"; then
    die "appcast.xml has no sparkle:edSignature — generate_appcast did not sign this entry. The app's SUPublicEDKey almost certainly does not match the private key in this keychain. An unsigned entry is rejected by every installed copy; do not publish it."
  fi

  # The single cheapest way to catch a post-signing rewrite: the length the
  # feed advertises must equal the DMG's real size. If these disagree, the
  # file was touched after it was signed and every user's update will fail
  # verification.
  local advertised actual
  advertised="$(grep -o "$dmg_name\"[^>]*length=\"[0-9]*\"" "$RELEASES_DIR/appcast.xml" \
                | grep -o 'length="[0-9]*"' | grep -o '[0-9]*' | tail -1)"
  actual="$(stat -f%z "$staged")"
  if [[ -n "$advertised" && "$advertised" != "$actual" ]]; then
    die "appcast length=$advertised does not match $dmg_name ($actual bytes) — the DMG changed after signing."
  fi

  say "Appcast ready"
  print -r -- "  $RELEASES_DIR/appcast.xml"
  print -r -- "  $staged"
  print -r -- ""
  print -r -- "  To publish, both of these must go out together:"
  print -r -- "    1. Upload $dmg_name as an asset on the 'v$version' GitHub release"
  print -r -- "       (the tag must be exactly 'v$version' — the feed's download URL assumes it)."
  print -r -- "    2. Commit appcast.xml to the gh-pages branch."
  print -r -- "  If the DMG is regenerated or re-uploaded afterwards, re-run this step."
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
appcast

say "Done"
print -r -- "  $DMG — signed, notarized, stapled, Gatekeeper-approved."
