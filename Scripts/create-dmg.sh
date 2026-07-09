#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
DMG_PATH="$DIST_DIR/CaptionBridge.dmg"
STAGE_ROOT="$(mktemp -d /private/tmp/CaptionBridgeDmg.XXXXXX)"
DMG_CONTENTS_DIR="$STAGE_ROOT/contents"
APP_DIR="$DMG_CONTENTS_DIR/CaptionBridge.app"
NOTARIZE="${CAPTIONBRIDGE_NOTARIZE:-0}"
NOTARY_PROFILE="${CAPTIONBRIDGE_NOTARY_KEYCHAIN_PROFILE:-}"
NOTARY_APPLE_ID="${CAPTIONBRIDGE_NOTARY_APPLE_ID:-}"
NOTARY_TEAM_ID="${CAPTIONBRIDGE_NOTARY_TEAM_ID:-}"
NOTARY_PASSWORD="${CAPTIONBRIDGE_NOTARY_PASSWORD:-}"
SIGN_IDENTITY="${CAPTIONBRIDGE_CODESIGN_IDENTITY:--}"
SIGN_KEYCHAIN="${CAPTIONBRIDGE_CODESIGN_KEYCHAIN:-}"
trap 'rm -rf "$STAGE_ROOT"' EXIT

has_signing_identity() {
  if [ -n "$SIGN_KEYCHAIN" ]; then
    security find-identity -v -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -Fq "\"$SIGN_IDENTITY\""
  else
    security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$SIGN_IDENTITY\""
  fi
}

case "$NOTARIZE" in
  0|"") ;;
  1)
    if [ "$SIGN_IDENTITY" = "-" ]; then
      echo "CAPTIONBRIDGE_NOTARIZE=1 requires CAPTIONBRIDGE_CODESIGN_IDENTITY." >&2
      exit 1
    fi
    case "$SIGN_IDENTITY" in
      "Developer ID Application:"*) ;;
      *)
        echo "Notarization requires a Developer ID Application signing identity." >&2
        exit 1
        ;;
    esac
    if ! has_signing_identity; then
      echo "Developer ID signing identity not found in the selected keychain: $SIGN_IDENTITY" >&2
      exit 1
    fi
    if [ -z "$NOTARY_PROFILE" ] && { [ -z "$NOTARY_APPLE_ID" ] || [ -z "$NOTARY_TEAM_ID" ] || [ -z "$NOTARY_PASSWORD" ]; }; then
      echo "Notarization requires CAPTIONBRIDGE_NOTARY_KEYCHAIN_PROFILE or all Apple ID credential variables." >&2
      exit 1
    fi
    ;;
  *)
    echo "CAPTIONBRIDGE_NOTARIZE must be 0 or 1." >&2
    exit 1
    ;;
esac

mkdir -p "$DMG_CONTENTS_DIR"
CAPTIONBRIDGE_OUTPUT_DIR="$DMG_CONTENTS_DIR" "$ROOT_DIR/Scripts/package-app.sh"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
cp "$ROOT_DIR/LICENSE" "$DMG_CONTENTS_DIR/LICENSE"
cp "$ROOT_DIR/THIRD-PARTY-NOTICES.md" "$DMG_CONTENTS_DIR/THIRD-PARTY-NOTICES.md"

rm -f "$DMG_PATH"
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/CaptionBridge.app"
hdiutil create \
  -volname "CaptionBridge" \
  -srcfolder "$DMG_CONTENTS_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [ "$NOTARIZE" = "1" ]; then
  if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$DMG_PATH" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait
  else
    xcrun notarytool submit "$DMG_PATH" \
      --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" \
      --wait
  fi
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

echo "Created $DMG_PATH"
