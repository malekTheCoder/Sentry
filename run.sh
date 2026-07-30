#!/bin/zsh
# Build and (re)launch MacStat.
#
# Two things on this machine make the plain `xcodebuild` line from the README
# fail, and both are worked around here rather than requiring a sudo password:
#
#   1. `xcode-select` points at /Library/Developer/CommandLineTools, which has
#      no xcodebuild. DEVELOPER_DIR overrides that per-invocation.
#   2. MacStat.xcodeproj is generated from project.yml and not committed, so it
#      has to be regenerated after a clone or any project.yml edit.
#
# Derived data goes to ./DerivedData (gitignored) rather than a temp dir so the
# built .app keeps a stable, Spotlight-visible path across runs.
set -euo pipefail

cd "$(dirname "$0")"

export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
DD="$PWD/DerivedData"
APP="$DD/Build/Products/Debug/MacStat.app"

/opt/homebrew/bin/xcodegen generate

xcodebuild -project MacStat.xcodeproj -scheme MacStat -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DD" build \
  2>&1 | grep -E "error:|warning: (unused|never)|BUILD (SUCCEEDED|FAILED)" | sort -u

# `open` on an already-running app just activates it, so kill first to be sure
# the relaunch actually picks up the build we just made.
pkill -f "MacStat.app/Contents/MacOS/MacStat" 2>/dev/null || true
sleep 1
open "$APP"
sleep 3

if pgrep -f "MacStat.app/Contents/MacOS/MacStat" >/dev/null; then
  echo "MacStat running — $(git rev-parse --short HEAD) $(git branch --show-current)"
else
  echo "MacStat failed to stay running; check Console.app for a crash report" >&2
  exit 1
fi
