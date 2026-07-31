#!/bin/zsh
# Build and (re)launch Sentry (product name of the MacStat project).
#
# Two things on this machine make the plain `xcodebuild` line from the README
# fail, and both are worked around here rather than requiring a sudo password:
#
#   1. `xcode-select` points at /Library/Developer/CommandLineTools, which has
#      no xcodebuild. DEVELOPER_DIR overrides that per-invocation.
#   2. MacStat.xcodeproj is generated from project.yml and not committed, so it
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

export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
DD="$HOME/Library/Developer/MacStat-DerivedData"
APP="$DD/Build/Products/Debug/Sentry.app"

/opt/homebrew/bin/xcodegen generate

xcodebuild -project MacStat.xcodeproj -scheme MacStat -configuration Debug \
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
# The old MacStat.app install is superseded by Sentry.app; clear both
# so two copies never race over the same settings and status item.
rm -rf /Applications/MacStat.app /Applications/Sentry.app
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
