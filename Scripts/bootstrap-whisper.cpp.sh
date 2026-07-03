#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/.build/whisper.cpp"
REPO_DIR="$TOOLS_DIR/source"
BUILD_DIR="$REPO_DIR/build"
LOCAL_CMAKE="$ROOT_DIR/.build/python-packages/cmake/data/bin/cmake"

if [ -x "$LOCAL_CMAKE" ]; then
  CMAKE="$LOCAL_CMAKE"
elif command -v cmake >/dev/null 2>&1; then
  CMAKE="$(command -v cmake)"
else
  echo "cmake is required to build whisper.cpp. Install it with pip into .build/python-packages or provide a prebuilt whisper-cli." >&2
  exit 1
fi

mkdir -p "$TOOLS_DIR"

if [ ! -d "$REPO_DIR/.git" ]; then
  git clone --depth 1 --branch v1.7.6 https://github.com/ggerganov/whisper.cpp.git "$REPO_DIR"
fi

"$CMAKE" -S "$REPO_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DGGML_NATIVE=OFF \
  -DGGML_ACCELERATE=ON \
  -DGGML_METAL=ON
"$CMAKE" --build "$BUILD_DIR" --config Release --target whisper-cli

echo "Built whisper-cli at $BUILD_DIR/bin/whisper-cli"
