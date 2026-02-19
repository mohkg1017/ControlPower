#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  scripts/install_to_applications.sh [--app /path/to/ControlPower.app] [--target /Applications/ControlPower.app]

Examples:
  scripts/install_to_applications.sh
  scripts/install_to_applications.sh --target /Applications/MoeRelease.app
  scripts/install_to_applications.sh --app .release/exported/ControlPower.app --target /Applications/MoeRelease.app
EOF
}

resolve_default_app_path() {
  local candidates=(
    "$ROOT_DIR/.release/exported/ControlPower.app"
    "$ROOT_DIR/.release/archives/ControlPower.xcarchive/Products/Applications/ControlPower.app"
    "$ROOT_DIR/.release/DerivedData/Build/Products/Release/ControlPower.app"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

APP_PATH=""
TARGET_PATH="/Applications/ControlPower.app"

while (( "$#" )); do
  case "$1" in
    --app)
      APP_PATH="$2"
      shift 2
      ;;
    --target)
      TARGET_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ "$1" == -* ]]; then
        echo "Unknown argument: $1"
        usage
        exit 1
      fi
      if [[ -z "$APP_PATH" ]]; then
        APP_PATH="$1"
      elif [[ "$TARGET_PATH" == "/Applications/ControlPower.app" ]]; then
        TARGET_PATH="$1"
      else
        echo "Unexpected positional argument: $1"
        usage
        exit 1
      fi
      shift 1
      ;;
  esac
done

if [[ -z "$APP_PATH" ]]; then
  if ! APP_PATH="$(resolve_default_app_path)"; then
    echo "No default release app found. Pass --app /path/to/ControlPower.app"
    exit 1
  fi
fi

TARGET_DIR="$(dirname "$TARGET_PATH")"
TARGET_NAME="$(basename "$TARGET_PATH" .app)"

if [[ "$TARGET_PATH" != *.app ]]; then
  echo "Target path must end with .app: $TARGET_PATH"
  exit 1
fi

STAGING_PATH="$TARGET_DIR/.${TARGET_NAME}.install.staging.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH"
  exit 1
fi

mkdir -p "$TARGET_DIR"
rm -rf "$STAGING_PATH"
ditto "$APP_PATH" "$STAGING_PATH"

if [[ -d "$TARGET_PATH" ]]; then
  BACKUP_PATH="$TARGET_DIR/${TARGET_NAME}.backup.$(date +%Y%m%d-%H%M%S).app"
  mv "$TARGET_PATH" "$BACKUP_PATH"
  echo "Backed up existing app to $BACKUP_PATH"
fi

mv "$STAGING_PATH" "$TARGET_PATH"

echo "Installed to $TARGET_PATH"
