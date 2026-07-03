#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
DMG_PATH="$DIST_DIR/CaptionBridge.dmg"
STAGE_ROOT="$(mktemp -d /private/tmp/CaptionBridgeDmg.XXXXXX)"
APP_DIR="$STAGE_ROOT/CaptionBridge.app"
trap 'rm -rf "$STAGE_ROOT"' EXIT

CAPTIONBRIDGE_OUTPUT_DIR="$STAGE_ROOT" "$ROOT_DIR/Scripts/package-app.sh"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

rm -f "$DMG_PATH"
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/CaptionBridge.app"
hdiutil create \
  -volname "CaptionBridge" \
  -srcfolder "$APP_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "Created $DMG_PATH"
