#!/usr/bin/env bash
# Build signed iOS companion and install on connected iPhone + paired Apple Watch.
# Usage:
#   ./tools/install_mobile_devices.sh           # incremental Xcode build
#   CLEAN=1 ./tools/install_mobile_devices.sh   # xcodebuild clean, then build
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH_DIR="$ROOT/apps/watch-ios"
PROJECT="$WATCH_DIR/TrackBallWatch.xcodeproj"

if [[ "${CLEAN:-0}" == "1" ]]; then
  echo "==> xcodebuild clean (CLEAN=1)"
  xcodebuild clean -project "$PROJECT" -alltargets
fi

echo "==> xcodebuild build (iOS + embedded Watch)"
xcodebuild build \
  -project "$PROJECT" \
  -scheme TrackBallWatch \
  -destination 'generic/platform=iOS' \
  -configuration Debug \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
xcrun devicectl list devices --json-output "$TMP" -q

export TMPFILE="$TMP"
IDS_OUT="$(python3 <<'PY'
import json, os, sys
with open(os.environ["TMPFILE"]) as f:
    d = json.load(f)
devices = d["result"]["devices"]
phone = next(
    (
        x["identifier"]
        for x in devices
        if x.get("hardwareProperties", {}).get("deviceType") == "iPhone"
    ),
    None,
)
watch = next(
    (
        x["identifier"]
        for x in devices
        if x.get("hardwareProperties", {}).get("deviceType") == "appleWatch"
    ),
    None,
)
if not phone:
    print("error: no iPhone in devicectl (connect USB / trust this Mac).", file=sys.stderr)
    sys.exit(1)
if not watch:
    print("error: no paired Apple Watch in devicectl.", file=sys.stderr)
    sys.exit(1)
print(phone)
print(watch)
PY
)"
PHONE_ID="$(echo "$IDS_OUT" | sed -n '1p')"
WATCH_ID="$(echo "$IDS_OUT" | sed -n '2p')"

APP_IOS="$(find "$HOME/Library/Developer/Xcode/DerivedData/TrackBallWatch-"*/Build/Products/Debug-iphoneos \
  -maxdepth 1 -name "TrackBallCompanion-iOS.app" 2>/dev/null | head -1)"
if [[ -z "$APP_IOS" || ! -d "$APP_IOS" ]]; then
  echo "error: TrackBallCompanion-iOS.app not found in DerivedData." >&2
  exit 1
fi

APP_WATCH="$APP_IOS/Watch/TrackBallWatch-watchOS.app"
# Fallback: standalone watchOS build artefact
if [[ ! -d "$APP_WATCH" ]]; then
  APP_WATCH="$(find "$HOME/Library/Developer/Xcode/DerivedData/TrackBallWatch-"*/Build/Products/Debug-watchos \
    -maxdepth 1 -name "TrackBallWatch-watchOS.app" 2>/dev/null | head -1)"
fi
if [[ -z "$APP_WATCH" || ! -d "$APP_WATCH" ]]; then
  echo "error: watch app not found in DerivedData." >&2
  exit 1
fi

echo "==> Installing iPhone app: $APP_IOS"
echo "    device: $PHONE_ID"
xcrun devicectl device install app --device "$PHONE_ID" "$APP_IOS"

echo "==> Installing Watch app: $APP_WATCH"
echo "    device: $WATCH_ID"
xcrun devicectl device install app --device "$WATCH_ID" "$APP_WATCH"

echo "Done: iPhone + Apple Watch."
