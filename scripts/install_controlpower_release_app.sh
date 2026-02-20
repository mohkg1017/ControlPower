#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
RUNNER_PATH="$ROOT_DIR/scripts/run_release_from_launcher.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/install_controlpower_release_app.sh [target-app-path]

Examples:
  scripts/install_controlpower_release_app.sh
  scripts/install_controlpower_release_app.sh /Applications/ControlPowerRelease.app
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

TARGET_APP="${1:-/Applications/ControlPowerRelease.app}"

if [[ "$TARGET_APP" != *.app ]]; then
  echo "Target must be an .app path: $TARGET_APP"
  exit 1
fi

if [[ ! -f "$RUNNER_PATH" ]]; then
  echo "Missing release runner script at $RUNNER_PATH"
  exit 1
fi

chmod +x "$RUNNER_PATH"

TARGET_DIR="$(dirname "$TARGET_APP")"
TARGET_NAME="$(basename "$TARGET_APP" .app)"
STAGING_APP="$TARGET_DIR/.${TARGET_NAME}.install.staging.app"
BACKUP_APP="$TARGET_DIR/${TARGET_NAME}.backup.$(date +%Y%m%d-%H%M%S).app"

rm -rf "$STAGING_APP"
mkdir -p "$STAGING_APP/Contents/MacOS"

ROOT_ESCAPED="${ROOT_DIR//\\/\\\\}"
ROOT_ESCAPED="${ROOT_ESCAPED//\"/\\\"}"
RUNNER_ESCAPED="${RUNNER_PATH//\\/\\\\}"
RUNNER_ESCAPED="${RUNNER_ESCAPED//\"/\\\"}"

cat > "$STAGING_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>ControlPowerRelease</string>
  <key>CFBundleIdentifier</key>
  <string>com.moe.controlpower.release-launcher</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>ControlPowerRelease</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
</dict>
</plist>
EOF

cat > "$STAGING_APP/Contents/MacOS/ControlPowerRelease" <<EOF
#!/bin/zsh
set -euo pipefail

RUNNER_PATH="$RUNNER_ESCAPED"

if [[ ! -x "\$RUNNER_PATH" ]]; then
  /usr/bin/osascript -e 'display alert "ControlPower release runner missing" message "Expected script not found or not executable." as critical'
  exit 1
fi

/usr/bin/osascript <<OSA
set rootPath to "$ROOT_ESCAPED"
set runnerPath to "$RUNNER_ESCAPED"
set commandText to "cd " & quoted form of rootPath & " && " & quoted form of runnerPath
tell application "Terminal"
  activate
  do script commandText
end tell
OSA
EOF

chmod +x "$STAGING_APP/Contents/MacOS/ControlPowerRelease"
mkdir -p "$TARGET_DIR"

if [[ -d "$TARGET_APP" ]]; then
  mv "$TARGET_APP" "$BACKUP_APP"
  echo "Backed up existing launcher to $BACKUP_APP"
fi

mv "$STAGING_APP" "$TARGET_APP"

CONFIG_FILE="$HOME/.controlpower-release.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
  cat > "$CONFIG_FILE" <<'EOF'
DEVELOPER_ID_APP='Developer ID Application: Your Name (TEAMID)'
# Optional for notarization:
# NOTARY_PROFILE='your-notary-profile'
EOF
  chmod 600 "$CONFIG_FILE"
  echo "Created $CONFIG_FILE (fill in real values before first release)."
fi

echo "Installed launcher app at $TARGET_APP"
