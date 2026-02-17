#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/ControlPower.xcodeproj"
SCHEME="ControlPower"
BUILD_DIR="$ROOT_DIR/.release"
DERIVED="$BUILD_DIR/DerivedData"
ARCHIVES="$BUILD_DIR/archives"
APP_NAME="ControlPower"

VERSION="${1:-1.0.0}"
BUILD="${2:-1}"

rm -rf "$BUILD_DIR"
mkdir -p "$ARCHIVES"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  build

APP_PATH="$DERIVED/Build/Products/Release/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app missing at $APP_PATH"
  exit 1
fi

if [[ -n "${DEVELOPER_ID_APP:-}" ]]; then
  echo "Signing app with: $DEVELOPER_ID_APP"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APP" "$APP_PATH/Contents/Resources/ControlPowerHelper" || true
  /usr/bin/codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APP" "$APP_PATH"
fi

DMG_PATH="$ARCHIVES/$APP_NAME-$VERSION.dmg"
DMGROOT="$BUILD_DIR/dmgroot"
mkdir -p "$DMGROOT"
rm -rf "$DMGROOT/$APP_NAME.app"
cp -R "$APP_PATH" "$DMGROOT/$APP_NAME.app"
ln -sf /Applications "$DMGROOT/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$DMGROOT" -ov -format UDZO "$DMG_PATH"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
fi

echo "DMG ready: $DMG_PATH"
