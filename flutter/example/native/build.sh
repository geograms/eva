#!/bin/bash -e
# Builds the Android arm64-v8a libcactus.so (C FFI exports) for the Flutter app
# and drops it into android/app/src/main/jniLibs/arm64-v8a/.
#
# The expensive part is compiling the Cactus engine from source. To keep local
# iteration fast this is content-addressed: the script hashes every native build
# input (CMakeLists, usearch, and the engine source — committed + local edits)
# and
#   1. skips entirely if the installed .so already matches that hash, or
#   2. restores a prior build of that hash from a machine-level cache
#      (~/.cache/cactus-ffi) — so a fresh checkout / cleaned tree does NOT
#      recompile the engine.
# Only a real change to native sources triggers an actual (incremental) compile.
# Set FORCE=1 to always recompile (e.g. after an NDK upgrade).

# Fail hard on any error: a -e in the shebang is ignored under `bash build.sh`,
# so set it explicitly (otherwise a failed cmake would still stamp a missing .so).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/build"
JNI_DIR="$APP_DIR/android/app/src/main/jniLibs/arm64-v8a"
SO="$JNI_DIR/libcactus.so"
STAMP="$JNI_DIR/.libcactus.so.hash"
CACHE_DIR="${CACTUS_FFI_CACHE:-$HOME/.cache/cactus-ffi}"
# Repo root: flutter/example/native -> three levels up.
CACTUS_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ANDROID_PLATFORM=${ANDROID_PLATFORM:-android-21}
ABI="arm64-v8a"

# sha256 of stdin, portable across Linux (sha256sum) and macOS (shasum).
if command -v sha256sum >/dev/null 2>&1; then
    _sha() { sha256sum | awk '{print $1}'; }
else
    _sha() { shasum -a 256 | awk '{print $1}'; }
fi

# A content signature of every native build input: the actual file contents of
# the engine sources (cactus/, cactus-engine/) and this native/ dir (CMakeLists
# + usearch). Purely content-based — no git, no mtimes — so it is identical no
# matter who/what invokes the script (interactive shell, Gradle, CI) and is
# stable across clones. Hashing ~150 files takes ~40ms.
compute_hash() {
    {
        echo "$ABI $ANDROID_PLATFORM"
        find "$CACTUS_ROOT/cactus" "$CACTUS_ROOT/cactus-engine" "$SCRIPT_DIR" \
            -type f -not -path '*/build/*' \
            \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' \
               -o -name '*.h' -o -name '*.hpp' -o -name 'CMakeLists.txt' \) \
            -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 cat 2>/dev/null
    } | _sha
}

HASH="$(compute_hash)"

# 1. Already installed and current — nothing to do (no NDK required).
if [ "${FORCE:-0}" != "1" ] && [ -f "$SO" ] && [ -f "$STAMP" ] \
        && [ "$(cat "$STAMP" 2>/dev/null)" = "$HASH" ]; then
    echo "libcactus.so up to date (${HASH:0:12}) — skipping native build."
    exit 0
fi

# 2. Built before on this machine — restore from cache (no NDK required).
CACHED="$CACHE_DIR/libcactus-$HASH.so"
if [ "${FORCE:-0}" != "1" ] && [ -f "$CACHED" ]; then
    mkdir -p "$JNI_DIR"
    cp "$CACHED" "$SO"
    echo "$HASH" > "$STAMP"
    echo "Restored libcactus.so from cache (${HASH:0:12})."
    exit 0
fi

# 3. Compile (incremental if $BUILD_DIR is warm). Needs the NDK.
if [ -z "$ANDROID_NDK_HOME" ]; then
    if [ -n "$ANDROID_NDK_LATEST_HOME" ]; then
        ANDROID_NDK_HOME="$ANDROID_NDK_LATEST_HOME"
    elif [ -n "$ANDROID_HOME" ]; then
        ANDROID_NDK_HOME=$(ls -d "$ANDROID_HOME/ndk/"* 2>/dev/null | sort -V | tail -1)
    fi
fi

if [ -z "$ANDROID_NDK_HOME" ] || [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "Error: Android NDK not found. Set ANDROID_NDK_HOME." >&2
    exit 1
fi

echo "Using NDK: $ANDROID_NDK_HOME"
echo "Building libcactus.so (${HASH:0:12})…"
TOOLCHAIN="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
n_cpu=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

cmake -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
      -DANDROID_ABI="$ABI" \
      -DANDROID_PLATFORM="$ANDROID_PLATFORM" \
      -DCMAKE_BUILD_TYPE=Release \
      -S "$SCRIPT_DIR" \
      -B "$BUILD_DIR" >/dev/null

cmake --build "$BUILD_DIR" --config Release -j "$n_cpu"

BUILT="$BUILD_DIR/lib/libcactus.so"
if [ ! -f "$BUILT" ]; then
    echo "Error: build did not produce $BUILT" >&2
    exit 1
fi
mkdir -p "$JNI_DIR"
cp "$BUILT" "$SO"
# Record the stamp + cache only after the .so is in place, so a failed build
# never leaves a stale stamp claiming success.
echo "$HASH" > "$STAMP"
mkdir -p "$CACHE_DIR"
cp "$SO" "$CACHED"
echo "Installed: $SO  (cached as ${HASH:0:12})"
