#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CaptionBridge"
OUTPUT_DIR="${CAPTIONBRIDGE_OUTPUT_DIR:-$ROOT_DIR/dist}"
OUTPUT_APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
STAGE_ROOT="$(mktemp -d /private/tmp/CaptionBridgePackage.XXXXXX)"
APP_DIR="$STAGE_ROOT/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ENTITLEMENTS_FILE="$ROOT_DIR/Packaging/CaptionBridge.entitlements"
RELEASE_BINARY="$ROOT_DIR/.build/arm64-apple-macosx/release/$APP_NAME"
FALLBACK_BINARY="$ROOT_DIR/.build/release/$APP_NAME"
WHISPER_HELPER_SOURCE="$ROOT_DIR/Tools/captionbridge-whisper-helper.c"
WHISPER_INCLUDE_DIR="$ROOT_DIR/.build/whisper.cpp/source/include"
GGML_INCLUDE_DIR="$ROOT_DIR/.build/whisper.cpp/source/ggml/include"
LOCAL_REQUIREMENT="=designated => identifier \"com.captionbridge.mac\""
SIGN_IDENTITY="${CAPTIONBRIDGE_CODESIGN_IDENTITY:--}"
SIGN_KEYCHAIN="${CAPTIONBRIDGE_CODESIGN_KEYCHAIN:-}"

cd "$ROOT_DIR"
trap 'rm -rf "$STAGE_ROOT"' EXIT

# Real (non ad-hoc) identities get hardened runtime + secure timestamp so a
# Developer ID build is notarization-ready out of the box.
HARDENING_FLAGS=""
if [ "$SIGN_IDENTITY" != "-" ]; then
  HARDENING_FLAGS="--options runtime --timestamp"
fi

sign_plain() {
  if [ -n "$SIGN_KEYCHAIN" ]; then
    codesign --force $HARDENING_FLAGS --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_IDENTITY" "$1"
  else
    codesign --force $HARDENING_FLAGS --sign "$SIGN_IDENTITY" "$1"
  fi
}

sign_app() {
  if [ "$SIGN_IDENTITY" = "-" ]; then
    if [ -n "$SIGN_KEYCHAIN" ]; then
      codesign --force --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS_FILE" -i "com.captionbridge.mac" -r "$LOCAL_REQUIREMENT" "$APP_DIR"
    else
      codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS_FILE" -i "com.captionbridge.mac" -r "$LOCAL_REQUIREMENT" "$APP_DIR"
    fi
  elif [ -n "$SIGN_KEYCHAIN" ]; then
    codesign --force $HARDENING_FLAGS --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS_FILE" -i "com.captionbridge.mac" "$APP_DIR"
  else
    codesign --force $HARDENING_FLAGS --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS_FILE" -i "com.captionbridge.mac" "$APP_DIR"
  fi
}

swift build -c release --arch arm64 --product "$APP_NAME"

if [ -x "$RELEASE_BINARY" ]; then
  BINARY="$RELEASE_BINARY"
elif [ -x "$FALLBACK_BINARY" ]; then
  BINARY="$FALLBACK_BINARY"
else
  echo "Could not find built $APP_NAME binary." >&2
  exit 1
fi

rm -rf "$APP_DIR" "$OUTPUT_APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BINARY" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Packaging/CaptionBridge-Info.plist" "$CONTENTS_DIR/Info.plist"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

if [ -f "$ROOT_DIR/Packaging/AppIcon.icns" ]; then
  cp "$ROOT_DIR/Packaging/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

if [ -d "$ROOT_DIR/.build/arm64-apple-macosx/release/CaptionBridge_CaptionBridgeApp.bundle" ]; then
  cp -R "$ROOT_DIR/.build/arm64-apple-macosx/release/CaptionBridge_CaptionBridgeApp.bundle" "$RESOURCES_DIR/"
fi

if [ -x "$ROOT_DIR/Tools/whisper-cli" ]; then
  mkdir -p "$RESOURCES_DIR/Tools"
  cp "$ROOT_DIR/Tools/whisper-cli" "$RESOURCES_DIR/Tools/whisper-cli"
elif [ -x "$ROOT_DIR/Vendor/whisper-cli" ]; then
  mkdir -p "$RESOURCES_DIR/Tools"
  cp "$ROOT_DIR/Vendor/whisper-cli" "$RESOURCES_DIR/Tools/whisper-cli"
elif [ -x "$ROOT_DIR/.build/whisper.cpp/source/build/bin/whisper-cli" ]; then
  mkdir -p "$RESOURCES_DIR/Tools"
  cp "$ROOT_DIR/.build/whisper.cpp/source/build/bin/whisper-cli" "$RESOURCES_DIR/Tools/whisper-cli"
  cp "$ROOT_DIR/.build/whisper.cpp/source/build/src/libwhisper.1.7.6.dylib" "$RESOURCES_DIR/Tools/libwhisper.1.7.6.dylib"
  ln -sf libwhisper.1.7.6.dylib "$RESOURCES_DIR/Tools/libwhisper.1.dylib"
  ln -sf libwhisper.1.dylib "$RESOURCES_DIR/Tools/libwhisper.dylib"
  cp "$ROOT_DIR/.build/whisper.cpp/source/build/ggml/src/libggml.dylib" "$RESOURCES_DIR/Tools/libggml.dylib"
  cp "$ROOT_DIR/.build/whisper.cpp/source/build/ggml/src/libggml-base.dylib" "$RESOURCES_DIR/Tools/libggml-base.dylib"
  cp "$ROOT_DIR/.build/whisper.cpp/source/build/ggml/src/libggml-cpu.dylib" "$RESOURCES_DIR/Tools/libggml-cpu.dylib"
  cp "$ROOT_DIR/.build/whisper.cpp/source/build/ggml/src/ggml-blas/libggml-blas.dylib" "$RESOURCES_DIR/Tools/libggml-blas.dylib"
  cp "$ROOT_DIR/.build/whisper.cpp/source/build/ggml/src/ggml-metal/libggml-metal.dylib" "$RESOURCES_DIR/Tools/libggml-metal.dylib"
  for RPATH in \
    "$ROOT_DIR/.build/whisper.cpp/source/build/src" \
    "$ROOT_DIR/.build/whisper.cpp/source/build/ggml/src" \
    "$ROOT_DIR/.build/whisper.cpp/source/build/ggml/src/ggml-blas" \
    "$ROOT_DIR/.build/whisper.cpp/source/build/ggml/src/ggml-metal"; do
    install_name_tool -delete_rpath "$RPATH" "$RESOURCES_DIR/Tools/whisper-cli" 2>/dev/null || true
  done
  install_name_tool -add_rpath "@executable_path" "$RESOURCES_DIR/Tools/whisper-cli" 2>/dev/null || true
  for DYLIB in "$RESOURCES_DIR"/Tools/*.dylib; do
    for RPATH in \
      "$ROOT_DIR/.build/whisper.cpp/source/build/src" \
      "$ROOT_DIR/.build/whisper.cpp/source/build/ggml/src" \
      "$ROOT_DIR/.build/whisper.cpp/source/build/ggml/src/ggml-blas" \
      "$ROOT_DIR/.build/whisper.cpp/source/build/ggml/src/ggml-metal"; do
      install_name_tool -delete_rpath "$RPATH" "$DYLIB" 2>/dev/null || true
    done
    install_name_tool -add_rpath "@loader_path" "$DYLIB" 2>/dev/null || true
  done
fi

if [ -f "$WHISPER_HELPER_SOURCE" ] && [ -d "$WHISPER_INCLUDE_DIR" ] && [ -d "$GGML_INCLUDE_DIR" ] && [ -f "$RESOURCES_DIR/Tools/libwhisper.dylib" ]; then
  cc \
    -std=c11 \
    -O2 \
    -D_DARWIN_C_SOURCE \
    -arch arm64 \
    -mmacosx-version-min=14.0 \
    -I "$WHISPER_INCLUDE_DIR" \
    -I "$GGML_INCLUDE_DIR" \
    "$WHISPER_HELPER_SOURCE" \
    -L "$RESOURCES_DIR/Tools" \
    -lwhisper \
    -Wl,-rpath,@executable_path \
    -o "$RESOURCES_DIR/Tools/captionbridge-whisper-helper"
fi

if [ ! -x "$RESOURCES_DIR/Tools/captionbridge-whisper-helper" ]; then
  echo "Missing persistent Whisper helper. Run Scripts/bootstrap-whisper.cpp.sh before packaging." >&2
  exit 1
fi

xattr -cr "$APP_DIR" 2>/dev/null || true
find "$APP_DIR" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
find "$APP_DIR" -exec xattr -d 'com.apple.fileprovider.fpfs#P' {} \; 2>/dev/null || true

if [ -d "$RESOURCES_DIR/Tools" ]; then
  find "$RESOURCES_DIR/Tools" -type f \( -name "*.dylib" -o -perm -111 \) -print | while IFS= read -r TOOL_FILE; do
    sign_plain "$TOOL_FILE"
  done
fi

sign_app
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

mkdir -p "$OUTPUT_DIR"
ditto --norsrc --noextattr "$APP_DIR" "$OUTPUT_APP_DIR" 2>/dev/null || ditto --norsrc "$APP_DIR" "$OUTPUT_APP_DIR"
xattr -cr "$OUTPUT_APP_DIR" 2>/dev/null || true
find "$OUTPUT_APP_DIR" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
find "$OUTPUT_APP_DIR" -exec xattr -d 'com.apple.fileprovider.fpfs#P' {} \; 2>/dev/null || true
if ! codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP_DIR"; then
  echo "Warning: strict verification failed for $OUTPUT_APP_DIR after copying to the output folder." >&2
  echo "The staged app was verified before copy; create-dmg.sh builds from a clean temporary staging folder." >&2
  codesign --verify --deep --verbose=2 "$OUTPUT_APP_DIR"
fi

echo "Packaged $OUTPUT_APP_DIR"
