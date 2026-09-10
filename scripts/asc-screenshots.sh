#!/bin/zsh
# Capture App Store Connect screenshots for the iPhone and Apple Watch apps.
#
# Sentry's Mac app ships Developer ID outside the Mac App Store (see the header
# of scripts/release.sh), so it needs no App Store screenshots at all. The
# iPhone app and its bundled Watch app do go through App Store Connect, and
# ASC rejects any screenshot that is not one of a short list of exact pixel
# sizes per device class. This script exists so that list is met by
# construction, every time the UI changes, rather than by someone remembering
# to open the right simulator and crop by hand.
#
# WHAT IT PRODUCES
#
#   build/asc-screenshots/iphone-6.9/      1320 × 2868  (iPhone 17 Pro Max)
#     01-dashboard-light.png  02-dashboard-dark.png
#     03-history-light.png    04-history-dark.png
#     05-alerts-light.png     06-alerts-dark.png
#   build/asc-screenshots/watch-ultra-49mm/  422 × 514  (Apple Watch Ultra 3)
#     01-overview.png         02-keep-awake.png
#   build/asc-screenshots/MANIFEST.txt     every file, its size, and whether
#                                          the app was on demo or live data
#
# `build/` is gitignored, like `dist/` for release.sh. Nothing here is committed.
#
# WHERE THE NUMBERS COME FROM
#
#   App Store Connect Help → Reference → "Screenshot specifications"
#   https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/
#   Checked 2026-09-10. The iPhone 6.9" class is *required* for every iPhone
#   app and accepts 1320×2868, 1290×2796 or 1260×2736; the Pro Max's native
#   1320×2868 is used. Apple Watch screenshots are *required* for any app that
#   bundles a Watch app; the Ultra 3 row is 422×514 and is the largest
#   supported case (Series 11 46mm would be 416×496 — `--watch-46mm`). ASC
#   wants one Watch size used consistently across all localisations.
#
#   If Apple changes the table, change `IPHONE_W/H` and the `WATCH_*` values
#   below *and* the URL/date above. The dimension check at the end is what
#   turns a stale number into a loud failure instead of a rejected upload.
#
# HOW IT WORKS
#
#   1. Verifies (or creates) a simulator of each exact device type.
#   2. `xcodegen generate`, then `xcodebuild build-for-testing` of the two
#      UI-test schemes — SentryMobileUITests and SentryWatchUITests — into a
#      DerivedData directory *outside* the repo (see DERIVED_DATA below).
#   3. Runs each UI-test bundle with `test-without-building`. The tests are
#      not tests: each method walks the app to one state and then *holds* it
#      (SentryMobileUITests/ScreenshotHandshake.swift) by writing
#      `<state>.ready` into a hand-off directory and waiting for
#      `<state>.done`. This loop watches for `.ready`, shoots with
#      `xcrun simctl io <udid> screenshot` — the one path that yields the
#      device's native pixel size exactly — flips light/dark where wanted,
#      and writes `.done`.
#   4. Checks every output file's pixel size with `sips` and fails if any
#      one is off by a pixel.
#
# WHAT THE SHOTS SHOW, AND WHY THAT IS HONEST
#
#   Demo data, disclosed as such. The iPhone app is launched with
#   `-SentryDemoData` (AppDataSource.isForcedDemoData, `#if DEBUG`), which
#   keeps it on MockDataSource exactly as a discovery timeout would, so the
#   "Sample data — not from a real Mac" banner and every SAMPLE tag are
#   genuinely on screen. The Watch app is launched with its pre-existing
#   `-SentryWatchDemo fullyPopulated` fixture, whose payload carries
#   `sourceIsDemoData: true` and therefore the "Demo" chip. The tests refuse
#   to hold a state without the disclosure on screen unless
#   SENTRY_SHOT_ALLOW_LIVE=1 (`--allow-live`) says that was deliberate.
#
#   The forced-demo argument is *why* this works on a developer's Mac at all:
#   a simulator shares that Mac's network, so if Sentry is running there
#   (which it will be, on the machine cutting a release) the phone app finds
#   it over Bonjour within seconds and switches to live readings under the
#   Mac's real name — and the History chart, which has no live source, goes
#   empty. Without the hook there is no demo state to photograph.
#
# WHAT THIS CANNOT CAPTURE
#
#   The keep-awake Live Activity (Dynamic Island / Lock Screen).
#   KeepAwakeActivityController refuses to start an activity from demo data
#   by design (`guard !(transport is MockDataSource)`), and this script will
#   not weaken that. Capturing it needs a real Mac running Sentry with an
#   active keep-awake, the phone app connected to it (no `-SentryDemoData`),
#   the app sent to the background, and then `xcrun simctl io <udid>
#   screenshot` by hand. That is a human-with-a-Mac job; it is listed as
#   such in docs/STATUS.md.
#
#   The Watch status bar clock. `simctl status_bar override` is iPhone-only;
#   the watch shows the simulator's real time.
#
# USAGE
#
#   scripts/asc-screenshots.sh                 # everything
#   scripts/asc-screenshots.sh --iphone-only   # or --watch-only
#   scripts/asc-screenshots.sh --skip-build    # reuse the last build-for-testing
#   scripts/asc-screenshots.sh --theme builtin.ivory
#   scripts/asc-screenshots.sh --watch-46mm    # Series 11 46mm (416×496) instead of Ultra
#   scripts/asc-screenshots.sh --allow-live    # permit shots of a real Mac's data
#   scripts/asc-screenshots.sh --keep-booted   # leave the simulators running
#   scripts/asc-screenshots.sh --purge-derived-data
#
# Environment: DEVELOPER_DIR (required — this machine's xcode-select points at
# CommandLineTools, so `export DEVELOPER_DIR=/Applications/Xcode-beta.app/
# Contents/Developer` first), DERIVED_DATA (default
# ~/Library/Developer/Sentry-DD-SHOTS — never inside the repo), OUT_DIR
# (default ./build/asc-screenshots), SHOT_THEME, WATCH_APPEARANCE
# (default dark).
#
# If `simctl` hangs on first use, CoreSimulator has wedged (a known quirk on
# this machine): `launchctl remove com.apple.CoreSimulator.CoreSimulatorService;
# pkill -9 -f CoreSimulator`, then re-run.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

# ── Configuration ────────────────────────────────────────────────────────────

OUT_DIR="${OUT_DIR:-$REPO_ROOT/build/asc-screenshots}"
DERIVED_DATA="${DERIVED_DATA:-$HOME/Library/Developer/Sentry-DD-SHOTS}"
SHOT_THEME="${SHOT_THEME:-}"
WATCH_APPEARANCE="${WATCH_APPEARANCE:-dark}"
WATCH_FIXTURE="fullyPopulated"
SPEC_URL="https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/"
SPEC_CHECKED="2026-09-10"

# iPhone 6.9" class — required. Native size of the iPhone 17 Pro Max.
IPHONE_NAME="iPhone 17 Pro Max"
IPHONE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"
IPHONE_W=1320; IPHONE_H=2868
IPHONE_SUBDIR="iphone-6.9"

# Apple Watch — required because SentryWatch is bundled. Largest case first.
WATCH_NAME="Apple Watch Ultra 3 (49mm)"
WATCH_TYPE="com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-3-49mm"
WATCH_W=422; WATCH_H=514
WATCH_SUBDIR="watch-ultra-49mm"

DO_IPHONE=1; DO_WATCH=1; SKIP_BUILD=0; ALLOW_LIVE=0; KEEP_BOOTED=0; PURGE_DD=0
while (( $# )); do
  case "$1" in
    --iphone-only) DO_WATCH=0 ;;
    --watch-only)  DO_IPHONE=0 ;;
    --skip-build)  SKIP_BUILD=1 ;;
    --allow-live)  ALLOW_LIVE=1 ;;
    --keep-booted) KEEP_BOOTED=1 ;;
    --purge-derived-data) PURGE_DD=1 ;;
    --theme) shift; [[ $# -gt 0 ]] || { print -u2 -- "--theme needs a theme id (e.g. builtin.ivory)"; exit 2; }; SHOT_THEME="$1" ;;
    --watch-46mm)
      WATCH_NAME="Apple Watch Series 11 (46mm)"
      WATCH_TYPE="com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm"
      WATCH_W=416; WATCH_H=496
      WATCH_SUBDIR="watch-series11-46mm" ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 -- "Unknown argument: $1 (try --help)"; exit 2 ;;
  esac
  shift
done
(( DO_IPHONE || DO_WATCH )) || { print -u2 -- "--iphone-only and --watch-only together leave nothing to do."; exit 2; }

say() { printf '\n▶ %s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }
warn() { printf '! %s\n' "$*" >&2; }

# ── Cleanup ──────────────────────────────────────────────────────────────────
#
# Registered before anything is booted or spawned so a failure halfway
# through still puts the machine back: no orphaned xcodebuild holding a
# simulator, no simulator left booted unless asked, no 9:41 status bar
# lingering on a device the user then opens for something else.

typeset -a BOOTED_BY_US
XCODEBUILD_PID=""
cleanup() {
  local rc=$?
  if [[ -n "$XCODEBUILD_PID" ]] && kill -0 "$XCODEBUILD_PID" 2>/dev/null; then
    kill "$XCODEBUILD_PID" 2>/dev/null || true
    wait "$XCODEBUILD_PID" 2>/dev/null || true
  fi
  for udid in "${BOOTED_BY_US[@]}"; do
    xcrun simctl status_bar "$udid" clear >/dev/null 2>&1 || true
    if (( ! KEEP_BOOTED )); then
      print -r -- "  Shutting down $udid"
      xcrun simctl shutdown "$udid" >/dev/null 2>&1 || warn "simctl shutdown $udid failed; it is still booted."
    fi
  done
  if (( PURGE_DD )) && [[ -d "$DERIVED_DATA" ]]; then
    rm -rf "$DERIVED_DATA"
  fi
  [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"
  exit $rc
}
trap cleanup EXIT INT TERM

# ── 0. Preflight ─────────────────────────────────────────────────────────────

preflight() {
  say "Preflight"

  [[ -n "${DEVELOPER_DIR:-}" ]] || die "DEVELOPER_DIR is not set. export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer (xcode-select on this machine points at CommandLineTools, which has no simulators)."
  [[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]] || die "DEVELOPER_DIR=$DEVELOPER_DIR has no xcodebuild."
  command -v xcodegen >/dev/null || die "xcodegen missing: brew install xcodegen"
  command -v jq >/dev/null || die "jq missing (ships with macOS 15+; otherwise brew install jq)"
  command -v sips >/dev/null || die "sips missing — this is not macOS?"
  [[ "$DERIVED_DATA" != "$REPO_ROOT"/* ]] || die "DERIVED_DATA=$DERIVED_DATA is inside the repo. Keep DerivedData out of the checkout."

  # A wedged CoreSimulator makes even `simctl list` hang for minutes; the
  # header says how to fix it. Nothing here can detect a hang without a
  # watchdog, so this is the first simctl call and it is deliberately the
  # cheapest one.
  xcrun simctl list -j runtimes > "$TMP/runtimes.json" || die "simctl is not answering — see the CoreSimulator note in this script's header."
  if (( DO_IPHONE )); then
    jq -e '.runtimes[] | select(.platform=="iOS" and .isAvailable)' "$TMP/runtimes.json" >/dev/null \
      || die "No available iOS simulator runtime. xcodebuild -downloadPlatform iOS"
  fi
  if (( DO_WATCH )); then
    jq -e '.runtimes[] | select(.platform=="watchOS" and .isAvailable)' "$TMP/runtimes.json" >/dev/null \
      || die "No available watchOS simulator runtime. xcodebuild -downloadPlatform watchOS"
  fi

  # A driver left over from an aborted run keeps its automation session on
  # the simulator, and a second session on the same device makes the app
  # relaunch under the first one's feet. Only drivers pointed at *this*
  # script's DerivedData are ours to stop; anything else on the machine is
  # someone else's build and is left alone.
  if pgrep -f "xcodebuild test-without-building.*$DERIVED_DATA" >/dev/null 2>&1; then
    warn "Stopping a stale screenshot driver from an earlier run."
    pkill -f "xcodebuild test-without-building.*$DERIVED_DATA" || true
    local waited=0
    while pgrep -f "xcodebuild test-without-building.*$DERIVED_DATA" >/dev/null 2>&1 && (( waited < 20 )); do sleep 1; waited=$(( waited + 1 )); done
    pkill -9 -f "xcodebuild test-without-building.*$DERIVED_DATA" 2>/dev/null || true
  fi

  if pgrep -f '/Sentry.app/Contents/MacOS/Sentry' >/dev/null 2>&1; then
    print -r -- "  Sentry.app is running on this Mac. That is fine: the simulator app is"
    print -r -- "  launched with -SentryDemoData and will not connect to it. Only"
    print -r -- "  --allow-live captures would ever show that Mac's readings."
  fi

  print -r -- "  Xcode:        $DEVELOPER_DIR"
  print -r -- "  DerivedData:  $DERIVED_DATA"
  print -r -- "  Output:       $OUT_DIR"
  print -r -- "  Spec:         $SPEC_URL (checked $SPEC_CHECKED)"
  [[ -n "$SHOT_THEME" ]] && print -r -- "  Theme:        $SHOT_THEME"
  return 0
}

# ── 1. Simulators ────────────────────────────────────────────────────────────
#
# Looked up by *device type identifier*, never by name or a hard-coded UDID:
# the pixel size is a property of the device type, and a device someone
# renamed or re-created still qualifies. Created on the newest available
# runtime for the platform when none exists.

ensure_device() {  # <platform iOS|watchOS> <device type id> <human name> → udid on stdout
  local platform="$1" type="$2" name="$3" udid runtime
  udid=$(xcrun simctl list -j devices available \
    | jq -r --arg t "$type" '[.devices | to_entries[] | .value[] | select(.deviceTypeIdentifier==$t and .isAvailable)] | first | .udid // empty')
  if [[ -z "$udid" ]]; then
    runtime=$(jq -r --arg p "$platform" '[.runtimes[] | select(.platform==$p and .isAvailable)] | sort_by(.version) | last | .identifier' "$TMP/runtimes.json")
    [[ -n "$runtime" && "$runtime" != "null" ]] || die "No $platform runtime to create '$name' on."
    print -u2 -- "  Creating '$name' on $runtime"
    udid=$(xcrun simctl create "$name" "$type" "$runtime") || die "simctl create failed for $name"
  fi
  print -r -- "$udid"
}

boot_device() {  # <udid> <name>
  local udid="$1" name="$2" state
  state=$(xcrun simctl list -j devices | jq -r --arg u "$udid" '.devices[][] | select(.udid==$u) | .state')
  if [[ "$state" != "Booted" ]]; then
    xcrun simctl boot "$udid" >/dev/null || die "Could not boot $name ($udid). If this is the first boot on this machine, see the CoreSimulator note in the header."
    BOOTED_BY_US+=("$udid")
  fi
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || die "$name never finished booting."
  print -r -- "  $name  $udid  (booted)"
}

# ── 2. Build ─────────────────────────────────────────────────────────────────

build_for_testing() {  # <scheme> <destination> <logname>
  local scheme="$1" dest="$2" log="$OUT_DIR/logs/$3.log"
  print -r -- "  $scheme → $log"
  xcodebuild build-for-testing \
      -project Sentry.xcodeproj -scheme "$scheme" -destination "$dest" \
      -derivedDataPath "$DERIVED_DATA" -quiet > "$log" 2>&1 \
    || { tail -40 "$log" >&2; die "build-for-testing failed for $scheme (full log: $log)"; }
}

# The xctestrun is what `test-without-building` consumes. Matched by scheme
# name only: Xcode names the file after the scheme's *run* platform, which
# for the Watch scheme comes out as `…_iphonesimulator…` even though the
# runner inside is the watchsimulator one.
xctestrun_for() {  # <scheme>
  local -a candidates
  candidates=("$DERIVED_DATA"/Build/Products/"$1"_*.xctestrun(N.om))
  (( ${#candidates} )) || die "No xctestrun for $1 under $DERIVED_DATA — run without --skip-build."
  print -r -- "${candidates[1]}"
}

# ── 3. Drive + capture ───────────────────────────────────────────────────────

# `simctl io screenshot` can refuse for a moment right after boot or an
# appearance flip while the display is re-composited; three tries a second
# apart cover that, and the last error is shown rather than swallowed.
# (`file`, not `path`: in zsh `path` is the array tied to `PATH`, and a
# `local path=…` silently empties it for the rest of the function — including
# an EXIT trap fired from inside it.)
shoot() {  # <udid> <file> <expected w> <expected h>
  local udid="$1" file="$2" w="$3" h="$4" attempt err
  for attempt in 1 2 3; do
    if err=$(xcrun simctl io "$udid" screenshot --type png "$file" 2>&1 >/dev/null) && [[ -s "$file" ]]; then
      check_dims "$file" "$w" "$h"
      return 0
    fi
    sleep 1
  done
  print -u2 -- "$err"
  die "simctl screenshot failed three times: $file"
}

check_dims() {  # <file> <w> <h>
  local file="$1" w="$2" h="$3" got
  got=$(sips -g pixelWidth -g pixelHeight "$file" 2>/dev/null | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w"x"h}')
  [[ "$got" == "${w}x${h}" ]] || die "$file is ${got}, expected ${w}x${h}. Wrong device type, or Apple changed the table — see the header."
}

# Runs one UI-test bundle in the background and services its hand-off files
# until every expected state has been captured. `capture_fn` is called as
# `capture_fn <state> <source>` where source is the test's own verdict,
# `demo` or `live`.
drive() {  # <label> <udid> <xctestrun> <destination> <capture_fn> <state>...
  local label="$1" udid="$2" xctestrun="$3" dest="$4" capture_fn="$5"; shift 5
  local -a pending; pending=("$@")
  local hs="$TMP/handshake-$label" log="$OUT_DIR/logs/test-$label.log" result="$OUT_DIR/logs/$label.xcresult"
  rm -rf "$hs" "$result"; mkdir -p "$hs"

  TEST_RUNNER_SENTRY_SHOT_HANDSHAKE_DIR="$hs" \
  TEST_RUNNER_SENTRY_SHOT_ALLOW_LIVE="$ALLOW_LIVE" \
  TEST_RUNNER_SENTRY_SHOT_THEME="$SHOT_THEME" \
  TEST_RUNNER_SENTRY_SHOT_WATCH_APPEARANCE="$WATCH_APPEARANCE" \
  TEST_RUNNER_SENTRY_SHOT_WATCH_FIXTURE="$WATCH_FIXTURE" \
  xcodebuild test-without-building -xctestrun "$xctestrun" -destination "$dest" \
      -resultBundlePath "$result" > "$log" 2>&1 &
  XCODEBUILD_PID=$!

  local start=$SECONDS state source
  while (( ${#pending} )); do
    if ! kill -0 "$XCODEBUILD_PID" 2>/dev/null; then break; fi
    (( SECONDS - start < 900 )) || die "Timed out driving $label after 15 minutes. Log: $log"
    for state in "${pending[@]}"; do
      if [[ -f "$hs/$state.ready" ]]; then
        source=$(<"$hs/$state.ready")
        "$capture_fn" "$state" "$source"
        touch "$hs/$state.done"
        pending=("${(@)pending:#$state}")
      fi
    done
    sleep 0.5
  done

  # Every state is captured; the tests themselves are over as far as this
  # script cares. Give the runner a couple of minutes to tear down on its
  # own (result bundle, simulator session), then stop it rather than sit
  # forever on an xcodebuild that has nothing left to do.
  local rc=0 waited=0
  while kill -0 "$XCODEBUILD_PID" 2>/dev/null && (( waited < 120 )); do sleep 1; waited=$(( waited + 1 )); done
  if kill -0 "$XCODEBUILD_PID" 2>/dev/null; then
    warn "$label driver did not exit within 120s of the last capture; stopping it."
    kill "$XCODEBUILD_PID" 2>/dev/null || true
  fi
  wait "$XCODEBUILD_PID" || rc=$?
  XCODEBUILD_PID=""
  # A non-zero exit *with* every state captured means only the teardown
  # complained (or was stopped above); the pictures are on disk and checked.
  if (( ${#pending} )); then
    grep -E 'error:|failed|XCTAssert' "$log" | head -20 >&2
    (( ${#pending} )) && print -u2 -- "  States never reached: ${pending[*]}"
    die "$label driver exited $rc. Full log: $log  Result bundle: $result"
  fi
}

typeset -a MANIFEST

capture_iphone() {  # <state> <source>
  local state="$1" source="$2" base dir="$OUT_DIR/$IPHONE_SUBDIR"
  case "$state" in
    iphone-dashboard) base="01-dashboard" ;;
    iphone-history)   base="03-history" ;;
    iphone-alerts)    base="05-alerts" ;;
    *) die "capture_iphone: unknown state $state" ;;
  esac
  # Light first (the appearance the device was left in), then dark, then
  # back to light so the next state starts where this one did. The app is
  # SwiftUI and re-renders on the flip; the sleep is for that redraw.
  xcrun simctl ui "$IPHONE_UDID" appearance light; sleep 1.5
  shoot "$IPHONE_UDID" "$dir/$base-light.png" "$IPHONE_W" "$IPHONE_H"
  xcrun simctl ui "$IPHONE_UDID" appearance dark; sleep 1.5
  local dark_base; dark_base="$(printf '%02d' $(( ${base%%-*} + 1 )))-${base#*-}"
  shoot "$IPHONE_UDID" "$dir/$dark_base-dark.png" "$IPHONE_W" "$IPHONE_H"
  xcrun simctl ui "$IPHONE_UDID" appearance light
  MANIFEST+=("$IPHONE_SUBDIR/$base-light.png	${IPHONE_W}x${IPHONE_H}	$source")
  MANIFEST+=("$IPHONE_SUBDIR/$dark_base-dark.png	${IPHONE_W}x${IPHONE_H}	$source")
  print -r -- "  ✓ $state ($source): $base-light.png, $dark_base-dark.png"
}

capture_watch() {  # <state> <source>
  local state="$1" source="$2" base dir="$OUT_DIR/$WATCH_SUBDIR"
  case "$state" in
    watch-overview)   base="01-overview" ;;
    watch-keep-awake) base="02-keep-awake" ;;
    *) die "capture_watch: unknown state $state" ;;
  esac
  shoot "$WATCH_UDID" "$dir/$base.png" "$WATCH_W" "$WATCH_H"
  MANIFEST+=("$WATCH_SUBDIR/$base.png	${WATCH_W}x${WATCH_H}	$source")
  print -r -- "  ✓ $state ($source): $base.png"
}

# ── Main ─────────────────────────────────────────────────────────────────────

TMP=$(mktemp -d "${TMPDIR:-/tmp}/asc-screenshots.XXXXXX")
mkdir -p "$OUT_DIR/logs"
preflight

say "Simulators"
IPHONE_UDID=""; WATCH_UDID=""
if (( DO_IPHONE )); then
  IPHONE_UDID=$(ensure_device iOS "$IPHONE_TYPE" "$IPHONE_NAME")
  print -r -- "  $IPHONE_NAME  $IPHONE_UDID  → ${IPHONE_W}×${IPHONE_H}"
fi
if (( DO_WATCH )); then
  WATCH_UDID=$(ensure_device watchOS "$WATCH_TYPE" "$WATCH_NAME")
  print -r -- "  $WATCH_NAME  $WATCH_UDID  → ${WATCH_W}×${WATCH_H}"
fi

if (( SKIP_BUILD )); then
  say "Build (skipped — reusing $DERIVED_DATA)"
else
  say "Build"
  xcodegen generate --quiet || die "xcodegen generate failed"
  (( DO_IPHONE )) && build_for_testing SentryMobileUITests "platform=iOS Simulator,id=$IPHONE_UDID" build-iphone
  (( DO_WATCH ))  && build_for_testing SentryWatchUITests  "platform=watchOS Simulator,id=$WATCH_UDID" build-watch
fi

if (( DO_IPHONE )); then
  say "iPhone — $IPHONE_NAME"
  rm -rf "$OUT_DIR/$IPHONE_SUBDIR"; mkdir -p "$OUT_DIR/$IPHONE_SUBDIR"
  boot_device "$IPHONE_UDID" "$IPHONE_NAME"
  # Apple's own marketing status bar: 9:41, full signal, full battery.
  xcrun simctl status_bar "$IPHONE_UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 >/dev/null
  xcrun simctl ui "$IPHONE_UDID" appearance light
  drive iphone "$IPHONE_UDID" "$(xctestrun_for SentryMobileUITests)" "platform=iOS Simulator,id=$IPHONE_UDID" \
    capture_iphone iphone-dashboard iphone-history iphone-alerts
fi

if (( DO_WATCH )); then
  say "Watch — $WATCH_NAME"
  rm -rf "$OUT_DIR/$WATCH_SUBDIR"; mkdir -p "$OUT_DIR/$WATCH_SUBDIR"
  boot_device "$WATCH_UDID" "$WATCH_NAME"
  drive watch "$WATCH_UDID" "$(xctestrun_for SentryWatchUITests)" "platform=watchOS Simulator,id=$WATCH_UDID" \
    capture_watch watch-overview watch-keep-awake
fi

# ── 4. Verify ────────────────────────────────────────────────────────────────
#
# Every capture was checked as it was taken; this re-walks the output
# directory so a stale file from an earlier run, or a state the driver
# skipped, cannot pass silently — and writes the manifest that says which
# data each picture shows.

say "Verify"
typeset -a expected
if (( DO_IPHONE )); then
  for f in 01-dashboard-light 02-dashboard-dark 03-history-light 04-history-dark 05-alerts-light 06-alerts-dark; do
    expected+=("$IPHONE_SUBDIR/$f.png	$IPHONE_W	$IPHONE_H")
  done
fi
if (( DO_WATCH )); then
  for f in 01-overview 02-keep-awake; do
    expected+=("$WATCH_SUBDIR/$f.png	$WATCH_W	$WATCH_H")
  done
fi
for entry in "${expected[@]}"; do
  local_path="${entry%%	*}"; rest="${entry#*	}"; w="${rest%%	*}"; h="${rest#*	}"
  [[ -f "$OUT_DIR/$local_path" ]] || die "Missing: $OUT_DIR/$local_path"
  check_dims "$OUT_DIR/$local_path" "$w" "$h"
  print -r -- "  ✓ ${w}×${h}  $local_path"
done

{
  print -r -- "# App Store Connect screenshots — generated $(date '+%Y-%m-%d %H:%M') by scripts/asc-screenshots.sh"
  print -r -- "# Spec: $SPEC_URL (checked $SPEC_CHECKED)"
  print -r -- "# iPhone 6.9\" class: $IPHONE_NAME, ${IPHONE_W}x${IPHONE_H}. Watch: $WATCH_NAME, ${WATCH_W}x${WATCH_H}."
  print -r -- "# Columns: file, pixels, data source as reported by the on-screen disclosure (demo = fabricated readings, disclosed in the shot)"
  [[ -n "$SHOT_THEME" ]] && print -r -- "# Theme: $SHOT_THEME"
  print -r -- "# Git: $(git rev-parse --short HEAD 2>/dev/null || print unknown)$(git diff --quiet 2>/dev/null || print ' (dirty)')"
  for line in "${MANIFEST[@]}"; do print -r -- "$line"; done
} > "$OUT_DIR/MANIFEST.txt"

if (( ALLOW_LIVE )) && printf '%s\n' "${MANIFEST[@]}" | grep -q '	live$'; then
  warn "Some shots show a real Mac's readings (see MANIFEST.txt). Check them for the Mac's name before uploading."
fi

say "Done"
print -r -- "  $OUT_DIR"
print -r -- "  ${#MANIFEST} files, all at the required pixel sizes. Manifest: $OUT_DIR/MANIFEST.txt"
print -r -- "  Not captured (needs a real Mac): keep-awake Live Activity — see the header."
