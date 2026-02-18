#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/ControlPower.app" >&2
  exit 64
fi

app_path="$1"
if [[ ! -d "$app_path" ]]; then
  echo "App bundle not found: $app_path" >&2
  exit 66
fi

entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null || true)"
normalized_entitlements="$(printf '%s' "$entitlements" | tr -d '[:space:]')"

if grep -q "com.apple.security.cs.disable-library-validation" <<<"$entitlements"; then
  echo "FAIL: release app contains com.apple.security.cs.disable-library-validation" >&2
  exit 1
fi

if grep -q "<key>com.apple.security.get-task-allow</key><true/>" <<<"$normalized_entitlements"; then
  echo "FAIL: release app has com.apple.security.get-task-allow=true" >&2
  exit 1
fi

helper_path="$app_path/Contents/Resources/ControlPowerHelper"
if [[ -f "$helper_path" ]]; then
  helper_entitlements="$(codesign -d --entitlements :- "$helper_path" 2>/dev/null || true)"
  helper_normalized_entitlements="$(printf '%s' "$helper_entitlements" | tr -d '[:space:]')"

  if grep -q "com.apple.security.cs.disable-library-validation" <<<"$helper_entitlements"; then
    echo "FAIL: release helper contains com.apple.security.cs.disable-library-validation" >&2
    exit 1
  fi

  if grep -q "<key>com.apple.security.get-task-allow</key><true/>" <<<"$helper_normalized_entitlements"; then
    echo "FAIL: release helper has com.apple.security.get-task-allow=true" >&2
    exit 1
  fi
fi

echo "PASS: release app/helper do not include disable-library-validation and are not debuggable"
