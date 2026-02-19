#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CONFIG_FILE="${CONTROLPOWER_RELEASE_ENV:-$HOME/.controlpower-release.env}"

if [[ -f "$CONFIG_FILE" ]]; then
  set -a
  source "$CONFIG_FILE"
  set +a
fi

if [[ -z "${DEVELOPER_ID_APP:-}" ]]; then
  cat <<EOF
error: DEVELOPER_ID_APP is required.

Create $CONFIG_FILE with:
  DEVELOPER_ID_APP='Developer ID Application: ...'
  NOTARY_PROFILE='your-notary-profile'   # optional, for notarization
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
  echo "Using NOTARY_PROFILE=$NOTARY_PROFILE"
else
  echo "NOTARY_PROFILE not set; notarization will be skipped."
fi

cd "$ROOT_DIR"
exec "$ROOT_DIR/scripts/release.sh" "$VERSION" "$BUILD"
