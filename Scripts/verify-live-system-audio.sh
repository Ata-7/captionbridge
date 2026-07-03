#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${CAPTIONBRIDGE_SOURCE_APP:-$ROOT_DIR/dist/CaptionBridge.app}"
DMG_PATH="$ROOT_DIR/dist/CaptionBridge.dmg"
TEST_APP="${CAPTIONBRIDGE_TEST_APP:-/private/tmp/CaptionBridge.app}"
LOG_PATH="${CAPTIONBRIDGE_LIVE_LOG:-/private/tmp/captionbridge-live.log}"
WORK_DIR="$(mktemp -d /private/tmp/CaptionBridgeLive.XXXXXX)"
SCREENSHOT_DIR="${CAPTIONBRIDGE_SCREENSHOT_DIR:-/private/tmp/CaptionBridgeLiveScreenshots.$$}"
CAPTURE_OVERLAY="${CAPTIONBRIDGE_CAPTURE_OVERLAY:-1}"
MOUNT_DIR=""

cleanup() {
  pkill -x CaptionBridge >/dev/null 2>&1 || true
  launchctl unsetenv CAPTIONBRIDGE_AUTOSTART >/dev/null 2>&1 || true
  launchctl unsetenv CAPTIONBRIDGE_EVENT_LOG >/dev/null 2>&1 || true
  launchctl unsetenv CAPTIONBRIDGE_SUBTITLE_DISPLAY >/dev/null 2>&1 || true
  if [ -n "$MOUNT_DIR" ]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    rm -rf "$MOUNT_DIR"
  fi
  rm -rf "$WORK_DIR"
}

trap cleanup EXIT INT TERM

if [ ! -d "$SOURCE_APP" ]; then
  if [ ! -f "$DMG_PATH" ]; then
    echo "Missing bundled app. Run Scripts/create-dmg.sh first." >&2
    exit 1
  fi

  MOUNT_DIR="$(mktemp -d /private/tmp/CaptionBridgeLiveMount.XXXXXX)"
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$DMG_PATH"
  SOURCE_APP="$MOUNT_DIR/CaptionBridge.app"
fi

rm -rf "$TEST_APP" "$LOG_PATH"
if [ "$CAPTURE_OVERLAY" = "1" ]; then
  rm -rf "$SCREENSHOT_DIR"
  mkdir -p "$SCREENSHOT_DIR"
fi
ditto --norsrc --noextattr "$SOURCE_APP" "$TEST_APP" 2>/dev/null || ditto --norsrc "$SOURCE_APP" "$TEST_APP"
xattr -cr "$TEST_APP" 2>/dev/null || true

codesign --verify --deep --strict --verbose=2 "$TEST_APP" >/dev/null

pkill -x CaptionBridge >/dev/null 2>&1 || true

launchctl setenv CAPTIONBRIDGE_AUTOSTART 1
launchctl setenv CAPTIONBRIDGE_EVENT_LOG "$LOG_PATH"
launchctl setenv CAPTIONBRIDGE_SUBTITLE_DISPLAY bilingual
open "$TEST_APP"

sleep 4

if [ ! -f "$LOG_PATH" ]; then
  echo "CaptionBridge did not create a live verification log." >&2
  exit 1
fi

if grep -q "start failed: CaptionBridge needs macOS Screen & System Audio Recording permission" "$LOG_PATH"; then
  cat "$LOG_PATH"
  echo "macOS is denying Screen & System Audio Recording for CaptionBridge." >&2
  echo "Enable CaptionBridge in Privacy & Security > Screen & System Audio Recording, then run this script again." >&2
  if [ "${CAPTIONBRIDGE_OPEN_PRIVACY_SETTINGS:-0}" = "1" ]; then
    open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'
  fi
  exit 2
fi

if ! grep -q "helper: Persistent Whisper helper ready" "$LOG_PATH"; then
  cat "$LOG_PATH"
  echo "Live verification did not observe the persistent Whisper helper." >&2
  exit 1
fi

if ! grep -q "display: bilingual" "$LOG_PATH"; then
  cat "$LOG_PATH"
  echo "Live verification did not enable bilingual display mode." >&2
  exit 1
fi

capture_overlay() {
  if [ "$CAPTURE_OVERLAY" = "1" ]; then
    screencapture -x "$SCREENSHOT_DIR/$1.png" >/dev/null 2>&1 || true
  fi
}

play_sentence() {
  slug="$1"
  text="$2"
  say -v Thomas -o "$WORK_DIR/$slug.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK_DIR/$slug.aiff" "$WORK_DIR/$slug.wav"
  afplay "$WORK_DIR/$slug.wav"
  sleep 1
  capture_overlay "$slug"
}

play_sentence "sentence-1" "Bonjour tout le monde. Nous allons commencer la réunion maintenant."
play_sentence "sentence-2" "Marie présentera les résultats du trimestre et les chiffres des ventes."
play_sentence "sentence-3" "Ensuite nous déciderons du budget et des prochaines étapes."
play_sentence "sentence-4" "Avant vendredi, chaque équipe doit envoyer ses questions."
play_sentence "sentence-5" "Le client demande une réponse claire sur le calendrier et les risques."
play_sentence "sentence-6" "Si nous terminons la préparation aujourd'hui, la démonstration sera plus simple demain."

sleep "${CAPTIONBRIDGE_LIVE_WAIT_SECONDS:-12}"
capture_overlay "final"

cat "$LOG_PATH"

final_count="$(grep -c "final:" "$LOG_PATH" || true)"

if [ "$final_count" -lt 3 ]; then
  echo "Live system-audio verification observed only $final_count final captions; expected at least 3." >&2
  exit 1
fi

if ! grep -Eq "overlay: .*[|].*[|]" "$LOG_PATH"; then
  echo "Live verification did not observe multiple final captions visible together in the overlay." >&2
  exit 1
fi

if ! grep -Eiq "final: .*(meeting|start)" "$LOG_PATH"; then
  echo "Live verification did not observe the meeting/start sentence." >&2
  exit 1
fi

if ! grep -Eiq "overlay: .*(meeting|start)" "$LOG_PATH"; then
  echo "Live verification did not observe the meeting/start sentence reaching the overlay." >&2
  exit 1
fi

if ! grep -Eiq "final: .*(result|quarter|semester|sales)" "$LOG_PATH"; then
  echo "Live verification did not observe the results/sales sentence." >&2
  exit 1
fi

if ! grep -Eiq "overlay: .*(result|quarter|semester|sales)" "$LOG_PATH"; then
  echo "Live verification did not observe the results/sales sentence reaching the overlay." >&2
  exit 1
fi

if ! grep -Eiq "final: .*(budget|next steps)" "$LOG_PATH"; then
  echo "Live verification did not observe the budget/next steps sentence." >&2
  exit 1
fi

if ! grep -Eiq "overlay: .*(budget|next steps)" "$LOG_PATH"; then
  echo "Live verification did not observe the budget/next steps sentence reaching the overlay." >&2
  exit 1
fi

if ! grep -Eiq "final: .*(friday|team|questions)" "$LOG_PATH"; then
  echo "Live verification did not observe the Friday/questions sentence." >&2
  exit 1
fi

if ! grep -Eiq "overlay: .*(friday|team|questions)" "$LOG_PATH"; then
  echo "Live verification did not observe the Friday/questions sentence reaching the overlay." >&2
  exit 1
fi

if ! grep -Eiq "final: .*(client|clear|calendar|schedule|risk)" "$LOG_PATH"; then
  echo "Live verification did not observe the client/calendar/risks sentence." >&2
  exit 1
fi

if ! grep -Eiq "overlay: .*(client|clear|calendar|schedule|risk)" "$LOG_PATH"; then
  echo "Live verification did not observe the client/calendar/risks sentence reaching the overlay." >&2
  exit 1
fi

if ! grep -Eiq "final: .*(preparation|today|demonstration|demo|tomorrow|simple)" "$LOG_PATH"; then
  echo "Live verification did not observe the preparation/demo sentence." >&2
  exit 1
fi

if ! grep -Eiq "overlay: .*(preparation|today|demonstration|demo|tomorrow|simple)" "$LOG_PATH"; then
  echo "Live verification did not observe the preparation/demo sentence reaching the overlay." >&2
  exit 1
fi

if grep -Eiq "timed out|error:" "$LOG_PATH"; then
  echo "Live verification observed a translation timeout or error." >&2
  exit 1
fi

if [ "$CAPTURE_OVERLAY" = "1" ] && find "$SCREENSHOT_DIR" -type f -name '*.png' -print -quit | grep -q .; then
  echo "Overlay screenshots saved to $SCREENSHOT_DIR"
elif [ "$CAPTURE_OVERLAY" = "1" ]; then
  echo "Shell screenshots were not available; overlay text was verified through app diagnostics."
fi

echo "Long live system-audio French-to-English caption verification passed."
