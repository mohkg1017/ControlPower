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

verify_signature() {
  local target_path="$1"
  local label="$2"
  if ! codesign --verify --strict --verbose=2 "$target_path" >/dev/null 2>&1; then
    echo "FAIL: codesign verification failed for $label at $target_path" >&2
    exit 1
  fi
}

check_hardened_runtime() {
  local target_path="$1"
  local label="$2"
  local signing_details
  if ! signing_details="$(codesign -d --verbose=4 "$target_path" 2>&1)"; then
    echo "FAIL: unable to inspect signing flags for $label at $target_path" >&2
    exit 1
  fi

  if ! grep -Eq 'flags=.*runtime|Runtime Version' <<<"$signing_details"; then
    echo "FAIL: $label is missing hardened runtime" >&2
    exit 1
  fi
}

read_entitlements() {
  local target_path="$1"
  local label="$2"
  local entitlements_xml
  if ! entitlements_xml="$(codesign -d --entitlements :- "$target_path" 2>/dev/null)"; then
    echo "FAIL: unable to read entitlements for $label at $target_path" >&2
    exit 1
  fi
  printf '%s' "$entitlements_xml"
}

is_allowed_entitlement_key() {
  local key="$1"
  shift
  local allowed
  for allowed in "$@"; do
    if [[ "$key" == "$allowed" ]]; then
      return 0
    fi
  done
  return 1
}

check_allowed_entitlements() {
  local entitlements_xml="$1"
  local label="$2"
  shift 2
  local allowed_keys=("$@")
  local entitlement_keys=()
  local key

  mapfile -t entitlement_keys < <(printf '%s\n' "$entitlements_xml" | sed -n 's@.*<key>\(.*\)</key>.*@\1@p')

  if (( ${#entitlement_keys[@]} == 0 )); then
    return
  fi

  if (( ${#allowed_keys[@]} == 0 )); then
    echo "FAIL: $label has unexpected entitlements; this release check expects none." >&2
    printf '%s\n' "${entitlement_keys[@]}" >&2
    exit 1
  fi

  for key in "${entitlement_keys[@]}"; do
    if ! is_allowed_entitlement_key "$key" "${allowed_keys[@]}"; then
      echo "FAIL: $label has unexpected entitlement '$key'" >&2
      exit 1
    fi
  done
}

check_entitlements() {
  local target_path="$1"
  local label="$2"
  local entitlements_xml normalized_entitlements

  verify_signature "$target_path" "$label"
  check_hardened_runtime "$target_path" "$label"
  entitlements_xml="$(read_entitlements "$target_path" "$label")"
  check_allowed_entitlements "$entitlements_xml" "$label"
  normalized_entitlements="$(printf '%s' "$entitlements_xml" | tr -d '[:space:]')"

  if grep -q "com.apple.security.cs.disable-library-validation" <<<"$entitlements_xml"; then
    echo "FAIL: $label contains com.apple.security.cs.disable-library-validation" >&2
    exit 1
  fi

  if grep -q "<key>com.apple.security.get-task-allow</key><true/>" <<<"$normalized_entitlements"; then
    echo "FAIL: $label has com.apple.security.get-task-allow=true" >&2
    exit 1
  fi

  if grep -q "<key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>" <<<"$normalized_entitlements"; then
    echo "FAIL: $label has com.apple.security.cs.allow-dyld-environment-variables=true" >&2
    exit 1
  fi
}

check_entitlements "$app_path" "release app"

helper_path="$app_path/Contents/Resources/ControlPowerHelper"
if [[ ! -f "$helper_path" ]]; then
  echo "FAIL: embedded helper missing at $helper_path" >&2
  exit 1
fi

check_entitlements "$helper_path" "release helper"

echo "PASS: release app/helper signatures are valid, hardened runtime is enabled, and entitlements are compliant"
