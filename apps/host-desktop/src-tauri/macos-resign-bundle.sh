#!/usr/bin/env bash
# Adhoc Tauri bundles are often linker-signed with Info.plist unbound; TCC then mis-matches
# Accessibility toggles. Re-sign the .app so the plist and bundle id seal with the executable.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || exit 0
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/target/release/bundle/macos/TrackBall Watch.app"
ENT="$ROOT/entitlements.plist"
[[ -d "$APP" && -f "$ENT" ]] || exit 0
codesign --force --sign - --entitlements "$ENT" --options runtime "$APP" 2>/dev/null \
  || codesign --force --sign - --entitlements "$ENT" "$APP"
