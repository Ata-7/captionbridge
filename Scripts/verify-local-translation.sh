#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_PATH="${CAPTIONBRIDGE_MODEL_PATH:-$HOME/Library/Application Support/CaptionBridge/Models/ggml-medium.bin}"
SOURCE_APP="${CAPTIONBRIDGE_SOURCE_APP:-$ROOT_DIR/dist/CaptionBridge.app}"
DMG_PATH="$ROOT_DIR/dist/CaptionBridge.dmg"
WORK_DIR="$(mktemp -d /private/tmp/CaptionBridgeVerify.XXXXXX)"
MOUNT_DIR=""

cleanup() {
  if [ -n "$MOUNT_DIR" ]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    rm -rf "$MOUNT_DIR"
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [ ! -d "$SOURCE_APP" ]; then
  if [ ! -f "$DMG_PATH" ]; then
    echo "Missing bundled app. Run Scripts/create-dmg.sh first." >&2
    exit 1
  fi

  MOUNT_DIR="$(mktemp -d /private/tmp/CaptionBridgeVerifyMount.XXXXXX)"
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$DMG_PATH"
  SOURCE_APP="$MOUNT_DIR/CaptionBridge.app"
fi

PERSISTENT_HELPER="$SOURCE_APP/Contents/Resources/Tools/captionbridge-whisper-helper"
CLI_HELPER="$SOURCE_APP/Contents/Resources/Tools/whisper-cli"

if [ ! -x "$PERSISTENT_HELPER" ] && [ ! -x "$CLI_HELPER" ]; then
  echo "Missing bundled Whisper helper. Run Scripts/package-app.sh first." >&2
  exit 1
fi

if [ ! -f "$MODEL_PATH" ]; then
  echo "Missing model at $MODEL_PATH" >&2
  exit 1
fi

say -v Thomas -o "$WORK_DIR/french.aiff" "Nous devons finaliser le rapport avant vendredi."
afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK_DIR/french.aiff" "$WORK_DIR/french.wav"

if [ -x "$PERSISTENT_HELPER" ]; then
  python3 - "$PERSISTENT_HELPER" "$MODEL_PATH" "$WORK_DIR/french.wav" > "$WORK_DIR/translation.txt" <<'PY'
import struct
import subprocess
import sys
import wave

helper_path, model_path, wave_path = sys.argv[1:4]
with wave.open(wave_path, "rb") as wav:
    if wav.getnchannels() != 1 or wav.getframerate() != 16000 or wav.getsampwidth() != 2:
        raise SystemExit("Unexpected WAV format for helper verification.")
    frames = wav.readframes(wav.getnframes())

sample_count = len(frames) // 2
pcm16 = struct.unpack("<" + "h" * sample_count, frames)
samples = struct.pack("<" + "f" * sample_count, *[value / 32768.0 for value in pcm16])
model_bytes = model_path.encode("utf-8")

process = subprocess.Popen(
    [helper_path],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
assert process.stdin is not None
assert process.stdout is not None

def request(request_id, task):
    header = f"REQ {request_id} {len(model_bytes)} fr 16000 {sample_count} 768 1 {task}\n".encode("utf-8")
    process.stdin.write(header)
    process.stdin.write(model_bytes)
    process.stdin.write(samples)
    process.stdin.flush()

    line = process.stdout.readline().decode("utf-8", errors="replace").strip()
    parts = line.split(" ")
    if len(parts) not in (4, 5):
        process.kill()
        raise SystemExit(f"Invalid helper response: {line}")

    status, response_id, elapsed_ms, byte_count = parts[:4]
    source_byte_count = int(parts[4]) if len(parts) == 5 else 0
    payload = process.stdout.read(int(byte_count))
    source_payload = process.stdout.read(source_byte_count)
    process.stdout.read(1)

    text = payload.decode("utf-8", errors="replace").strip()
    source_text = source_payload.decode("utf-8", errors="replace").strip()
    if status not in ("OK", "OK2"):
        raise SystemExit(f"Helper failed: {text}")
    if response_id != str(request_id):
        raise SystemExit(f"Unexpected helper response id: {response_id}")

    return text, source_text, elapsed_ms

source_text, _, source_elapsed = request(1, "source")
text, _, translation_elapsed = request(2, "translate")
dual_text, dual_source_text, dual_elapsed = request(3, "dual")
process.stdin.close()
process.terminate()
process.wait(timeout=2)

if not source_text:
    raise SystemExit("Helper did not return French source text.")
if not dual_source_text:
    raise SystemExit("Helper did not return bilingual final source text.")

print(dual_text or text)
print(f"[source: {source_text}]", file=sys.stderr)
print(f"[dual source: {dual_source_text}]", file=sys.stderr)
print(f"[persistent helper source: {source_elapsed} ms, translate: {translation_elapsed} ms, dual: {dual_elapsed} ms]", file=sys.stderr)
PY
else
  "$CLI_HELPER" \
    -m "$MODEL_PATH" \
    -f "$WORK_DIR/french.wav" \
    -l fr \
    -tr \
    -nt \
    -np \
    -bo 1 \
    -bs 1 \
    -nf \
    -ac 768 \
    -otxt \
    -of "$WORK_DIR/translation" >/dev/null
fi

TRANSLATION="$(cat "$WORK_DIR/translation.txt" | tr '[:upper:]' '[:lower:]')"
echo "$TRANSLATION"

case "$TRANSLATION" in
  *report*friday*|*finish*report*)
    echo "Local French-to-English translation verified."
    ;;
  *)
    echo "Unexpected translation output." >&2
    exit 1
    ;;
esac
