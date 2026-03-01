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
LOCK_DIR="$ROOT_DIR/.release.lock"

VERSION="${1:-1.0.0}"
BUILD="${2:-1}"
TEST_CONFIGURATION="${TEST_CONFIGURATION:-Debug}"
TEST_DESTINATION="${TEST_DESTINATION:-platform=macOS,arch=$(uname -m)}"
TEST_TIMEOUTS_ENABLED="${TEST_TIMEOUTS_ENABLED:-YES}"
DEFAULT_TEST_EXECUTION_TIMEOUT="${DEFAULT_TEST_EXECUTION_TIMEOUT:-120}"
MAX_TEST_EXECUTION_TIMEOUT="${MAX_TEST_EXECUTION_TIMEOUT:-600}"

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

if [[ -z "${NOTARY_PROFILE:-}" && "${ALLOW_UNNOTARIZED_RELEASE:-0}" != "1" ]]; then
  echo "error: NOTARY_PROFILE is required for release builds."
  echo "error: set ALLOW_UNNOTARIZED_RELEASE=1 only when you intentionally want a non-notarized build."
  exit 1
fi

if [[ -f "$ROOT_DIR/project.yml" ]]; then
  if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate --spec "$ROOT_DIR/project.yml"
  else
    echo "error: xcodegen is required when project.yml is present"
    exit 1
  fi
fi

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid"
    return 0
  fi

  if [[ -f "$LOCK_DIR/pid" ]]; then
    local existing_pid
    existing_pid="$(<"$LOCK_DIR/pid")"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      echo "error: another release run is already in progress (pid $existing_pid, lock: $LOCK_DIR)"
      exit 1
    fi
  fi

  echo "warning: removing stale release lock at $LOCK_DIR"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
  echo "$$" > "$LOCK_DIR/pid"
}

acquire_lock
trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

rm -rf "$BUILD_DIR"
mkdir -p "$ARCHIVES" "$EXPORT_DIR"

run_tests_once() {
  local attempt="$1"
  local log_file="$BUILD_DIR/test-attempt-${attempt}.log"
  local result_bundle="$BUILD_DIR/test-attempt-${attempt}.xcresult"
  local timeout_args=()

  rm -rf "$result_bundle"

  if [[ "$TEST_TIMEOUTS_ENABLED" == "YES" ]]; then
    timeout_args=(
      -test-timeouts-enabled YES
      -default-test-execution-time-allowance "$DEFAULT_TEST_EXECUTION_TIMEOUT"
      -maximum-test-execution-time-allowance "$MAX_TEST_EXECUTION_TIMEOUT"
    )
  else
    timeout_args=(-test-timeouts-enabled NO)
  fi

  echo "Running tests (attempt $attempt) for destination: $TEST_DESTINATION"
  if [[ "$TEST_TIMEOUTS_ENABLED" == "YES" ]]; then
    echo "Test timeouts enabled (default=${DEFAULT_TEST_EXECUTION_TIMEOUT}s, max=${MAX_TEST_EXECUTION_TIMEOUT}s)."
  else
    echo "Test timeouts disabled via TEST_TIMEOUTS_ENABLED=NO."
  fi

  set +e
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$TEST_CONFIGURATION" \
    -derivedDataPath "$DERIVED" \
    -destination "$TEST_DESTINATION" \
    -resultBundlePath "$result_bundle" \
    "${timeout_args[@]}" \
    test 2>&1 | tee "$log_file"
  local test_exit_code=${pipestatus[1]}
  set -e

  return "$test_exit_code"
}

is_xctest_bundle_load_failure() {
  local log_file="$1"
  rg -q "Failed to create a bundle instance representing '.*ControlPowerTests.xctest'" "$log_file"
}

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
  if run_tests_once 1; then
    :
  else
    run_exit_code="$?"
    if is_xctest_bundle_load_failure "$BUILD_DIR/test-attempt-1.log"; then
      echo "warning: xctest could not load ControlPowerTests.xctest. Retrying once with fresh test artifacts..."
      rm -rf "$DERIVED/Build/Products/$TEST_CONFIGURATION/ControlPowerTests.xctest" "$DERIVED/Logs/Test"

      if run_tests_once 2; then
        :
      else
        second_run_exit_code="$?"
        if is_xctest_bundle_load_failure "$BUILD_DIR/test-attempt-2.log"; then
          echo "error: repeated xctest bundle-load failure detected. Aborting release."
          echo "error: see $BUILD_DIR/test-attempt-1.log and $BUILD_DIR/test-attempt-2.log"
          exit "$second_run_exit_code"
        else
          exit "$second_run_exit_code"
        fi
      fi
    else
      exit "$run_exit_code"
    fi
  fi
else
  echo "warning: SKIP_TESTS=1 set; proceeding without running tests."
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

HELPER_PATH="$ARCHIVE_APP_PATH/Contents/MacOS/ControlPowerHelper"
if [[ ! -f "$HELPER_PATH" ]]; then
  echo "Missing helper binary at $HELPER_PATH"
  exit 1
fi

echo "Signing app with: $DEVELOPER_ID_APP"
/usr/bin/codesign --force --options runtime --timestamp --identifier "com.moe.controlpower.helper.bin" --sign "$DEVELOPER_ID_APP" "$HELPER_PATH"

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
echo "DMG created: $DMG_PATH"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_SUBMIT_JSON="$ARCHIVES/notary-submit.json"
  NOTARY_LOG_JSON="$ARCHIVES/notary-log.json"
  echo "Submitting DMG for notarization with profile '$NOTARY_PROFILE' (this can take several minutes)..."
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
  echo "warning: ALLOW_UNNOTARIZED_RELEASE=1 set; skipping notarization and stapling"
fi

echo "DMG ready: $DMG_PATH"
