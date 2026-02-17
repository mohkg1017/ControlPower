#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/.release/DerivedData/Build/Products/Release/ControlPower.app}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH"
  exit 1
fi

ditto "$APP_PATH" /Applications/ControlPower.app

echo "Installed to /Applications/ControlPower.app"
