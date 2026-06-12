#!/bin/bash -e
# Downloads the most recent Eva Android APK from the GitHub release into this
# folder (as Eva.apk), ready to install or share.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="https://github.com/geograms/eva/releases/latest/download/cactus-android-arm64-v8a.apk"
OUT="$DIR/Eva.apk"

echo "Downloading the latest Eva APK..."
curl -fL --progress-bar "$URL" -o "$OUT"
echo "Saved: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Install with: adb install -r \"$OUT\"  (or share the file directly)"
