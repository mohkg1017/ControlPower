#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CONFIG_FILE="${CONTROLPOWER_RELEASE_ENV:-$HOME/.controlpower-release.env}"

validate_release_config_permissions() {
  local config_file="$1"
  local owner_uid current_uid permissions permission_value

  owner_uid="$(stat -f "%u" "$config_file")"
  current_uid="$(id -u)"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    echo "error: $config_file must be owned by the current user (uid $current_uid)."
    exit 1
  fi

  permissions="$(stat -f "%Lp" "$config_file")"
  permission_value=$((8#$permissions))
  if (( (permission_value & 077) != 0 )); then
    echo "error: $config_file permissions are too broad ($permissions)."
    echo "Set secure permissions with: chmod 600 $config_file"
    exit 1
  fi
}

load_release_config() {
  local config_file="$1"
  local raw_line line key value

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="${raw_line#"${raw_line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" != [A-Za-z_][A-Za-z0-9_]*=* ]]; then
      echo "error: invalid config line in $config_file: $line"
      exit 1
    fi

    key="${line%%=*}"
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
      value="${value:1:${#value}-2}"
    fi

    case "$key" in
      DEVELOPER_ID_APP|NOTARY_PROFILE|RUN_TESTS|SKIP_TESTS|ALLOW_UNNOTARIZED_RELEASE)
        export "$key=$value"
        ;;
      *)
        echo "warning: ignoring unsupported key '$key' in $config_file"
        ;;
    esac
  done < "$config_file"
}

if [[ -f "$CONFIG_FILE" ]]; then
  validate_release_config_permissions "$CONFIG_FILE"
  load_release_config "$CONFIG_FILE"
fi

if [[ -z "${DEVELOPER_ID_APP:-}" ]]; then
  cat <<EOF
error: DEVELOPER_ID_APP is required.

Create $CONFIG_FILE with:
  DEVELOPER_ID_APP='Developer ID Application: ...'
  NOTARY_PROFILE='your-notary-profile'
EOF
  exit 1
fi

if [[ "$DEVELOPER_ID_APP" == "Developer ID Application: ..." ]]; then
  echo "error: DEVELOPER_ID_APP is still a placeholder in $CONFIG_FILE"
  echo "Set it to a real identity, for example:"
  security find-identity -v -p codesigning | grep "Developer ID Application" || true
  exit 1
fi

if [[ "${NOTARY_PROFILE:-}" == "your-notary-profile" ]]; then
  echo "NOTARY_PROFILE is still placeholder text; notarization will be skipped."
  unset NOTARY_PROFILE
fi

if [[ "${RUN_TESTS:-0}" == "1" ]]; then
  SKIP_TESTS=0
elif [[ -z "${SKIP_TESTS:-}" ]]; then
  SKIP_TESTS=0
fi

if [[ "${SKIP_TESTS:-0}" == "1" ]]; then
  echo "Skipping tests in launcher flow because SKIP_TESTS=1."
fi

if [[ -z "${NOTARY_PROFILE:-}" && "${ALLOW_UNNOTARIZED_RELEASE:-0}" != "1" ]]; then
  echo "error: NOTARY_PROFILE is required (set ALLOW_UNNOTARIZED_RELEASE=1 to bypass notarization intentionally)."
  exit 1
fi

VERSION="${1:-}"
BUILD="${2:-}"

if [[ -z "$VERSION" ]]; then
  printf "Release version [1.0.0]: "
  read -r VERSION_INPUT
  VERSION="${VERSION_INPUT:-1.0.0}"
fi

if [[ -z "$BUILD" ]]; then
  DEFAULT_BUILD="$(date +%Y%m%d%H%M)"
  printf "Build number [%s]: " "$DEFAULT_BUILD"
  read -r BUILD_INPUT
  BUILD="${BUILD_INPUT:-$DEFAULT_BUILD}"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "Using configured notary profile."
else
  echo "ALLOW_UNNOTARIZED_RELEASE=1 set; notarization will be skipped."
fi

cd "$ROOT_DIR"
export SKIP_TESTS
exec "$ROOT_DIR/scripts/release.sh" "$VERSION" "$BUILD"
