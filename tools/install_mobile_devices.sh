#!/usr/bin/env bash
# Build signed iOS companion (with embedded Watch app) and install on connected iPhone.
# The paired Apple Watch receives its app automatically via iPhone companion push.
#
# Usage:
#   ./tools/install_mobile_devices.sh                    # incremental iPhone build + install
#   CLEAN=1 ./tools/install_mobile_devices.sh            # xcodebuild clean, then build + install
#   PROVISION_WATCH=1 ./tools/install_mobile_devices.sh  # also try explicit watchOS provisioning
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH_DIR="$ROOT/apps/watch-ios"
PROJECT="$WATCH_DIR/TrackBallWatch.xcodeproj"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/.codex-derived/mobile-install}"
PROVISION_WATCH="${PROVISION_WATCH:-0}"

run_xcodebuild_filtered() {
    local log_file
    log_file="$(mktemp)"

    if "$@" >"$log_file" 2>&1; then
        grep -E "^(error:|warning: provisioning|BUILD SUCCEEDED|BUILD FAILED)" "$log_file" || true
        rm -f "$log_file"
        return 0
    fi

    grep -E "^(error:|warning: provisioning|BUILD SUCCEEDED|BUILD FAILED)" "$log_file" || true
    echo "error: xcodebuild failed. Last 60 log lines:" >&2
    tail -n 60 "$log_file" >&2 || true
    rm -f "$log_file"
    return 1
}

run_xcodebuild_clean() {
    local log_file
    log_file="$(mktemp)"

    if "$@" >"$log_file" 2>&1; then
        grep -E "^(error:|BUILD|CLEAN)" "$log_file" || true
        rm -f "$log_file"
        return 0
    fi

    grep -E "^(error:|BUILD|CLEAN)" "$log_file" || true
    echo "error: xcodebuild clean failed. Last 60 log lines:" >&2
    tail -n 60 "$log_file" >&2 || true
    rm -f "$log_file"
    return 1
}

# ── Find devices ──────────────────────────────────────────────────────────────

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
xcrun devicectl list devices --json-output "$TMP" -q

read -r PHONE_ID WATCH_UDID <<< "$(python3 <<PY
import json, os, sys
with open("$TMP") as f:
    d = json.load(f)
devs = d["result"]["devices"]
phone = next(
    (x for x in devs
     if x.get("hardwareProperties", {}).get("deviceType") == "iPhone"
     and x.get("deviceProperties", {}).get("ddiServicesAvailable") == True),
    None,
)
watch = next(
    (x for x in devs
     if x.get("hardwareProperties", {}).get("deviceType") == "appleWatch"),
    None,
)
if not phone:
    print("error: no iPhone with ddiServicesAvailable=true (connect via USB and trust this Mac).", file=sys.stderr)
    sys.exit(1)
# Watch UDID comes from hardwareProperties.udid (physical UDID for provisioning)
watch_udid = watch.get("hardwareProperties", {}).get("udid", "") if watch else ""
print(phone["identifier"], watch_udid)
PY
)"

echo "==> iPhone: $PHONE_ID"
if [[ -n "$WATCH_UDID" ]]; then
    echo "==> Watch UDID: $WATCH_UDID"
else
    echo "==> Watch UDID: <not found>"
fi

# ── Optional clean ────────────────────────────────────────────────────────────

if [[ "${CLEAN:-0}" == "1" ]]; then
    echo "==> xcodebuild clean (CLEAN=1)"
    run_xcodebuild_clean \
        xcodebuild clean \
        -project "$PROJECT" \
        -scheme TrackBallWatch \
        -derivedDataPath "$DERIVED_DATA_PATH"
fi

# ── Step 1: Build iOS scheme with embedded Watch app ──────────────────────────
# `devicectl` returns a CoreDevice identifier that `xcodebuild -destination`
# does not reliably accept for iPhone builds. Use a generic iOS destination for
# the build, then install the resulting app onto the concrete phone via devicectl.

echo "==> Building iOS + embedded Watch scheme..."
run_xcodebuild_filtered \
    xcodebuild build \
    -project "$PROJECT" \
    -scheme TrackBallWatch \
    -destination "generic/platform=iOS" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration

# ── Step 2: Optional direct watchOS provisioning ───────────────────────────────
# Default flow is bundle-only: install the iPhone companion and let iOS deliver
# the embedded Watch app. Direct watchOS provisioning is opt-in because it can
# fail on connection/unlock issues even when the bundle path via iPhone is fine.

if [[ "$PROVISION_WATCH" == "1" && -n "$WATCH_UDID" ]]; then
    echo "==> Provisioning Watch device ($WATCH_UDID)..."
    run_xcodebuild_filtered \
        xcodebuild build \
        -project "$PROJECT" \
        -scheme TrackBallWatch-watchOS \
        -destination "platform=watchOS,id=$WATCH_UDID" \
        -configuration Debug \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -allowProvisioningUpdates \
        -allowProvisioningDeviceRegistration
elif [[ "$PROVISION_WATCH" == "1" ]]; then
    echo "==> Watch provisioning requested, but no Watch UDID was found. Skipping."
else
    echo "==> Skipping direct Watch provisioning (bundle-only flow)."
fi

# ── Step 3: Find built iOS .app ───────────────────────────────────────────────

APP_IOS="$DERIVED_DATA_PATH/Build/Products/Debug-iphoneos/TrackBallCompanion-iOS.app"
if [[ -z "$APP_IOS" || ! -d "$APP_IOS" ]]; then
    echo "error: TrackBallCompanion-iOS.app not found at $APP_IOS." >&2
    exit 1
fi
echo "==> App: $APP_IOS"

# ── Step 4: Install iOS app on iPhone ─────────────────────────────────────────
# Embedded Watch app (.app/Watch/) will be pushed to the Watch automatically
# by iOS when the companion app is opened on iPhone.

echo "==> Installing on iPhone..."
xcrun devicectl device install app --device "$PHONE_ID" "$APP_IOS"

echo ""
echo "Done. Open the TrackBall Watch app on iPhone — iOS will push the Watch app automatically."
