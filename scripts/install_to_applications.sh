#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/.release/DerivedData/Build/Products/Release/ControlPower.app}"
TARGET_PATH="/Applications/ControlPower.app"
STAGING_PATH="/Applications/.ControlPower.install.staging.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH"
  exit 1
fi

rm -rf "$STAGING_PATH"
ditto "$APP_PATH" "$STAGING_PATH"

if [[ -d "$TARGET_PATH" ]]; then
  BACKUP_PATH="/Applications/ControlPower.backup.$(date +%Y%m%d-%H%M%S).app"
  mv "$TARGET_PATH" "$BACKUP_PATH"
  echo "Backed up existing app to $BACKUP_PATH"
fi

mv "$STAGING_PATH" "$TARGET_PATH"

echo "Installed to $TARGET_PATH"
