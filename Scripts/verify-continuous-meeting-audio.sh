#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${CAPTIONBRIDGE_SOURCE_APP:-$ROOT_DIR/dist/CaptionBridge.app}"
DMG_PATH="$ROOT_DIR/dist/CaptionBridge.dmg"
TEST_APP="${CAPTIONBRIDGE_TEST_APP:-/private/tmp/CaptionBridge.app}"
LOG_PATH="${CAPTIONBRIDGE_CONTINUOUS_LOG:-/private/tmp/captionbridge-continuous.log}"
WORK_DIR="$(mktemp -d /private/tmp/CaptionBridgeContinuous.XXXXXX)"
SAY_RATE="${CAPTIONBRIDGE_SAY_RATE:-235}"
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

  MOUNT_DIR="$(mktemp -d /private/tmp/CaptionBridgeContinuousMount.XXXXXX)"
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$DMG_PATH"
  SOURCE_APP="$MOUNT_DIR/CaptionBridge.app"
fi

rm -rf "$TEST_APP" "$LOG_PATH"
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
  echo "CaptionBridge did not create a continuous verification log." >&2
  exit 1
fi

if ! grep -q "helper: Persistent Whisper helper ready" "$LOG_PATH"; then
  cat "$LOG_PATH"
  echo "Continuous verification did not observe the persistent Whisper helper." >&2
  exit 1
fi

if ! grep -q "display: bilingual" "$LOG_PATH"; then
  cat "$LOG_PATH"
  echo "Continuous verification did not enable bilingual display mode." >&2
  exit 1
fi

cat > "$WORK_DIR/meeting.txt" <<'TEXT'
Bonjour à tous, merci d'être là. Aujourd'hui nous devons revoir le planning du projet, confirmer le budget, décider qui contacte le client, et préparer la démonstration pour demain. Marie, peux-tu expliquer rapidement les résultats du trimestre, puis Hassan donnera les risques principaux, surtout les délais de livraison et les problèmes de qualité. Si le client demande une réponse claire, nous devons dire que l'équipe peut terminer la préparation aujourd'hui, mais seulement si les questions techniques arrivent avant seize heures. Ensuite nous parlerons des prochaines étapes, de la formation, et du document final que chaque équipe doit envoyer vendredi matin. Je vais avancer sans m'arrêter parce que dans une vraie réunion les phrases s'enchaînent et il faut que les sous-titres restent lisibles pendant que la traduction continue.
TEXT

say -v Thomas -r "$SAY_RATE" -o "$WORK_DIR/continuous.aiff" -f "$WORK_DIR/meeting.txt"
afplay "$WORK_DIR/continuous.aiff"
sleep "${CAPTIONBRIDGE_CONTINUOUS_WAIT_SECONDS:-14}"

cat "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import datetime as dt
import re
import sys

log_path = sys.argv[1]
lines = open(log_path, encoding="utf-8", errors="replace").read().splitlines()

finals = []
overlays = []
errors = []
for line in lines:
    if " error:" in line or "timed out" in line.lower():
        errors.append(line)
    match = re.match(r"^(\S+) final: (.*)$", line)
    if match:
        timestamp = dt.datetime.fromisoformat(match.group(1).replace("Z", "+00:00"))
        finals.append((timestamp, match.group(2).lower()))
    match = re.match(r"^(\S+) overlay: (.*)$", line)
    if match:
        overlays.append(match.group(2).lower())

if errors:
    raise SystemExit("Continuous verification observed errors:\n" + "\n".join(errors[:5]))

if len(finals) < 5:
    raise SystemExit(f"Continuous verification observed only {len(finals)} final captions; expected at least 5.")

gaps = [
    (later[0] - earlier[0]).total_seconds()
    for earlier, later in zip(finals, finals[1:])
]
if gaps and max(gaps) > 11:
    raise SystemExit(f"Continuous verification saw a long final-caption gap: {max(gaps):.1f}s.")

joined_finals = " ".join(text for _, text in finals)
keyword_groups = [
    (("budget",), "budget"),
    (("client", "customer"), "client/customer"),
    (("risk", "risks"), "risks"),
    (("demonstration", "demo"), "demonstration/demo"),
    (("friday",), "Friday"),
]
missing = [
    label
    for keywords, label in keyword_groups
    if not any(keyword in joined_finals for keyword in keywords)
]
if missing:
    raise SystemExit("Continuous verification missed expected topics: " + ", ".join(missing))

joined_overlays = " ".join(overlays)
for keyword in ["bonjour", "client", "vendredi"]:
    if keyword not in joined_overlays:
        raise SystemExit(f"Continuous verification missed French source text in overlay: {keyword}")

multi_caption_overlays = [text for text in overlays if text.count("|") >= 2]
if len(multi_caption_overlays) < 2:
    raise SystemExit("Continuous verification did not observe stable multi-caption overlay history.")

print(f"Continuous meeting verification passed with {len(finals)} final captions; max final gap {max(gaps) if gaps else 0:.1f}s.")
PY
