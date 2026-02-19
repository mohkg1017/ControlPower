#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

"$ROOT_DIR/scripts/install_to_applications.sh" \
  --target /Applications/MoeRelease.app \
  "$@"
