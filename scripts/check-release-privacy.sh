#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/ControlPower.app-or.dmg" >&2
  exit 64
fi

artifact_path="$1"
if [[ ! -e "$artifact_path" ]]; then
  echo "Release artifact not found: $artifact_path" >&2
  exit 66
fi

temp_dir=""
mounted=0
scan_root="$artifact_path"

cleanup() {
  if (( mounted )); then
    hdiutil detach "$scan_root" -quiet >/dev/null 2>&1 || true
  fi
  if [[ -n "$temp_dir" ]]; then
    rm -rf "$temp_dir"
  fi
}
trap cleanup EXIT

if [[ "$artifact_path" == *.dmg ]]; then
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/controlpower-release-privacy.XXXXXX")"
  scan_root="$temp_dir/mount"
  mkdir -p "$scan_root"
  hdiutil attach "$artifact_path" -readonly -nobrowse -mountpoint "$scan_root" -quiet
  mounted=1
fi

failures=()

record_failure() {
  failures+=("$1")
}

relative_path() {
  local path="$1"
  printf '%s' "${path#$scan_root/}"
}

forbidden_name_expr=(
  -name .git
  -o -name .audit
  -o -name .build
  -o -name .cursor
  -o -name scratch
  -o -name CLAUDE.md
  -o -name .continues-handoff.md
  -o -name build_log.txt
  -o -name default.profraw
  -o -name .controlpower-release.env
  -o -name notary-submit.json
  -o -name notary-log.json
  -o -name '*.p12'
  -o -name '*.pem'
  -o -name '*.key'
  -o -name '*.mobileprovision'
)

while IFS= read -r -d '' forbidden_path; do
  record_failure "forbidden release file: $(relative_path "$forbidden_path")"
done < <(find "$scan_root" \( "${forbidden_name_expr[@]}" \) -print0)

if [[ "$artifact_path" == *.dmg ]]; then
  while IFS= read -r -d '' top_level_path; do
    top_level_name="$(basename "$top_level_path")"
    if [[ "$top_level_name" != "ControlPower.app" && "$top_level_name" != "Applications" ]]; then
      record_failure "unexpected top-level DMG item: $top_level_name"
    fi
  done < <(find "$scan_root" -mindepth 1 -maxdepth 1 -print0)
fi

secret_labels=(
  "local user path"
  "macOS private workspace path"
  "release env filename"
  "GitHub token"
  "private key"
  "developer identity variable"
  "notary profile variable"
  "local AI config path"
  "personal email"
)

secret_patterns=(
  '/Users/moekanan'
  '/Users/[A-Za-z0-9._-]+/(Code|Desktop|Downloads|Documents|Library|\.codex|\.claude|\.ssh)'
  '\.controlpower-release\.env'
  'gh[pousr]_[A-Za-z0-9_]{20,}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'DEVELOPER_ID_APP='
  'NOTARY_PROFILE='
  '(\.claude|\.codex|\.cursor|CLAUDE\.md)'
  'mohammedkanan1997@gmail\.com'
)

while IFS= read -r -d '' file_path; do
  [[ -r "$file_path" ]] || continue

  strings_output="$(mktemp "${TMPDIR:-/tmp}/controlpower-release-strings.XXXXXX")"
  if ! LC_ALL=C strings -a "$file_path" > "$strings_output" 2>/dev/null; then
    rm -f "$strings_output"
    continue
  fi

  for index in "${!secret_patterns[@]}"; do
    if grep -E -q -- "${secret_patterns[$index]}" "$strings_output"; then
      record_failure "${secret_labels[$index]} marker in $(relative_path "$file_path")"
    fi
  done

  rm -f "$strings_output"
done < <(find "$scan_root" -type f -size -50M -print0)

if (( ${#failures[@]} > 0 )); then
  echo "FAIL: release privacy check found data that should not be published:" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi

echo "PASS: release privacy check found no local/private data markers in $(basename "$artifact_path")"
