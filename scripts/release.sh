#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/ControlPower.xcodeproj"
SCHEME="ControlPower"
BUILD_DIR="$ROOT_DIR/.release"
DERIVED="$BUILD_DIR/DerivedData"
ARCHIVES="$BUILD_DIR/archives"
EXPORT_DIR="$BUILD_DIR/exported"
APP_NAME="ControlPower"

VERSION="${1:-1.0.0}"
BUILD="${2:-1}"
TEST_CONFIGURATION="${TEST_CONFIGURATION:-Debug}"
TEST_DESTINATION="${TEST_DESTINATION:-platform=macOS,arch=$(uname -m)}"

if [[ -z "${DEVELOPER_ID_APP:-}" ]]; then
  echo "error: DEVELOPER_ID_APP is required for release builds"
  echo "error: export DEVELOPER_ID_APP='Developer ID Application: ...'"
  exit 1
fi

if [[ "$DEVELOPER_ID_APP" == "Developer ID Application: ..." ]]; then
  echo "error: DEVELOPER_ID_APP is still set to the placeholder value."
  echo "error: set it to your real signing identity first."
  exit 1
fi

if [[ "${NOTARY_PROFILE:-}" == "your-notary-profile" ]]; then
  echo "warning: NOTARY_PROFILE is set to placeholder value; skipping notarization."
  unset NOTARY_PROFILE
fi

if [[ -f "$ROOT_DIR/project.yml" ]]; then
  if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate --spec "$ROOT_DIR/project.yml"
  else
    echo "warning: xcodegen not found; skipping project regeneration"
  fi
fi

rm -rf "$BUILD_DIR"
mkdir -p "$ARCHIVES" "$EXPORT_DIR"

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
  for attempt in 1 2; do
    if xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$TEST_CONFIGURATION" \
      -derivedDataPath "$DERIVED" \
      -destination "$TEST_DESTINATION" \
      test; then
      break
    fi

    if [[ "$attempt" -eq 2 ]]; then
      echo "error: tests failed after retry."
      exit 1
    fi

    echo "warning: tests failed on first attempt; retrying once."
    rm -rf "$DERIVED/Logs/Test"
  done
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -archivePath "$ARCHIVES/$APP_NAME.xcarchive" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  archive

ARCHIVE_PATH="$ARCHIVES/$APP_NAME.xcarchive"
ARCHIVE_APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
if [[ ! -d "$ARCHIVE_APP_PATH" ]]; then
  echo "Archived app missing at $ARCHIVE_APP_PATH"
  exit 1
fi

APP_PATH="$ARCHIVE_APP_PATH"

HELPER_PATH="$ARCHIVE_APP_PATH/Contents/Resources/ControlPowerHelper"
if [[ ! -f "$HELPER_PATH" ]]; then
  echo "Missing helper binary at $HELPER_PATH"
  exit 1
fi

echo "Signing app with: $DEVELOPER_ID_APP"
/usr/bin/codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APP" "$HELPER_PATH"

if [[ -d "$ARCHIVE_APP_PATH/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' framework; do
    /usr/bin/codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APP" "$framework"
  done < <(find "$ARCHIVE_APP_PATH/Contents/Frameworks" -type d -name '*.framework' -print0)
fi

/usr/bin/codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APP" "$ARCHIVE_APP_PATH"

EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
if [[ "${RUN_EXPORT_ARCHIVE:-0}" == "1" ]]; then
  cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
</dict>
</plist>
EOF

  if xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS"; then
    EXPORTED_APP_PATH="$EXPORT_DIR/$APP_NAME.app"
    if [[ -d "$EXPORTED_APP_PATH" ]]; then
      APP_PATH="$EXPORTED_APP_PATH"
    fi
  else
    echo "warning: exportArchive failed; using archived app instead"
  fi
else
  echo "Skipping exportArchive; using archived app for DMG packaging."
fi

bash "$ROOT_DIR/scripts/check-release-entitlements.sh" "$APP_PATH"

DSYM_PATH="$ARCHIVE_PATH/dSYMs/$APP_NAME.app.dSYM"
if [[ -d "$DSYM_PATH" ]]; then
  rm -rf "$ARCHIVES/$APP_NAME.app.dSYM"
  cp -R "$DSYM_PATH" "$ARCHIVES/$APP_NAME.app.dSYM"
fi

DMG_PATH="$ARCHIVES/$APP_NAME-$VERSION.dmg"
DMGROOT="$BUILD_DIR/dmgroot"
mkdir -p "$DMGROOT"
rm -rf "$DMGROOT/$APP_NAME.app"
cp -R "$APP_PATH" "$DMGROOT/$APP_NAME.app"
ln -sf /Applications "$DMGROOT/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$DMGROOT" -ov -format UDZO "$DMG_PATH"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_SUBMIT_JSON="$ARCHIVES/notary-submit.json"
  NOTARY_LOG_JSON="$ARCHIVES/notary-log.json"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$NOTARY_SUBMIT_JSON"

  NOTARY_ID="$(/usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("id") or d.get("jobId") or d.get("submissionId") or "")' "$NOTARY_SUBMIT_JSON")"
  NOTARY_STATUS="$(/usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("status") or "")' "$NOTARY_SUBMIT_JSON")"

  if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    echo "error: notarization failed with status: ${NOTARY_STATUS:-unknown}"
    if [[ -n "$NOTARY_ID" ]]; then
      xcrun notarytool log "$NOTARY_ID" --keychain-profile "$NOTARY_PROFILE" "$NOTARY_LOG_JSON" || true
      if [[ -f "$NOTARY_LOG_JSON" ]]; then
        cat "$NOTARY_LOG_JSON"
      fi
    fi
    exit 1
  fi

  xcrun stapler staple "$DMG_PATH"
else
  echo "warning: NOTARY_PROFILE not set; skipping notarization and stapling"
fi

echo "DMG ready: $DMG_PATH"
