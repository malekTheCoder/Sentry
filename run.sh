#!/bin/zsh
# Build and (re)launch Sentry (product name of the Sentry project).
#
# Two things on this machine make the plain `xcodebuild` line from the README
# fail, and both are worked around here rather than requiring a sudo password:
#
#   1. `xcode-select` points at /Library/Developer/CommandLineTools, which has
#      no xcodebuild. DEVELOPER_DIR overrides that per-invocation.
#   2. Sentry.xcodeproj is generated from project.yml and not committed, so it
#      has to be regenerated after a clone or any project.yml edit.
#
# Derived data must live OUTSIDE this repo: the repo sits in ~/Documents,
# which iCloud/FileProvider syncs, and the sync stamps com.apple.FinderInfo /
# fileprovider xattrs onto build products — codesign then fails with
# "resource fork, Finder information, or similar detritus not allowed" for
# any signed target (the widget appex, the ad-hoc-signed app). A stable path
# under ~/Library keeps the built .app Spotlight-visible across runs.
set -euo pipefail

cd "$(dirname "$0")"

# Xcode-beta was hardcoded here and silently stopped existing when it was
# replaced by a release Xcode — every run then died on "missing DEVELOPER_DIR
# path" before building anything. Prefer whichever is actually installed, and
# fall back to whatever xcode-select points at rather than guessing.
for candidate in /Applications/Xcode-beta.app /Applications/Xcode.app; do
  if [ -d "$candidate/Contents/Developer" ]; then
    export DEVELOPER_DIR="$candidate/Contents/Developer"
  fi
done
if [ -z "${DEVELOPER_DIR:-}" ]; then
  DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
  export DEVELOPER_DIR
fi
if [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
  echo "No usable Xcode found (DEVELOPER_DIR=$DEVELOPER_DIR). Install Xcode or run: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi
DD="$HOME/Library/Developer/Sentry-DerivedData"
APP="$DD/Build/Products/Debug/Sentry.app"

/opt/homebrew/bin/xcodegen generate

xcodebuild -project Sentry.xcodeproj -scheme Sentry -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DD" build \
  2>&1 | grep -E "error:|warning: (unused|never)|BUILD (SUCCEEDED|FAILED)" | sort -u

# Install into /Applications rather than launching from DerivedData: that's
# the location Spotlight and (once the project has a real signing team)
# chronod's widget discovery both expect. `ditto` preserves the signature;
# `xattr -cr` strips any FileProvider detritus that would upset codesign
# checks later.
#
# `open` on an already-running app just activates it, so kill first to be sure
# the relaunch actually picks up the build we just made.
pkill -f "Sentry.app/Contents/MacOS/Sentry" 2>/dev/null || true
sleep 1
# The old Sentry.app install is superseded by Sentry.app; clear both
# so two copies never race over the same settings and status item.
rm -rf /Applications/Sentry.app /Applications/Sentry.app
ditto "$APP" /Applications/Sentry.app
xattr -cr /Applications/Sentry.app 2>/dev/null || true
open /Applications/Sentry.app
sleep 3

if pgrep -f "Sentry.app/Contents/MacOS/Sentry" >/dev/null; then
  echo "Sentry running — $(git rev-parse --short HEAD) $(git branch --show-current)"
else
  echo "Sentry failed to stay running; check Console.app for a crash report" >&2
  exit 1
fi
