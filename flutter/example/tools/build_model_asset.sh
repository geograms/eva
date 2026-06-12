#!/bin/bash -e
# Transpiles a model into a loadable bundle and packs it as the Flutter app's
# bundled asset (flutter/example/assets/model.zip).
#
# Requires the Cactus Python toolchain (run `source ./setup` at the repo root).
# This is a host-side, one-time step — the device cannot transpile.

MODEL=${1:-LiquidAI/LFM2.5-350M}
BITS=${2:-4}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "$APP_DIR/../.." && pwd)"

OUT_DIR="$REPO_ROOT/weights/lfm2.5-350m-int4"
ASSET="$APP_DIR/assets/model.zip"

PY="$REPO_ROOT/venv/bin/python"
[ -x "$PY" ] || PY=python3

echo "Transpiling $MODEL (int$BITS) -> $OUT_DIR"
"$PY" "$SCRIPT_DIR/transpile_model.py" "$MODEL" "$OUT_DIR" "$BITS"

if [ ! -f "$OUT_DIR/components/manifest.json" ]; then
    echo "Error: transpile did not produce components/manifest.json" >&2
    exit 1
fi

mkdir -p "$APP_DIR/assets"
rm -f "$ASSET"
echo "Packing bundle -> $ASSET"
( cd "$OUT_DIR" && zip -r -1 -q "$ASSET" . -x '*.zip' )
echo "Asset ready: $ASSET ($(du -h "$ASSET" | cut -f1))"
