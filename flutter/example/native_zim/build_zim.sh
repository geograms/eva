#!/bin/bash
# Builds the offline-Wikipedia native bits for arm64-v8a and installs them:
#   - libzimffi.so   : our C ABI shim (compiled here)
#   - libzim.so      : prebuilt libzim (Xapian/zstd/lzma/ICU statically inside)
#   - libc++_shared.so : the C++ runtime libzim needs (libcactus statically
#                        links its own, so it isn't present otherwise)
# into android/app/src/main/jniLibs/arm64-v8a/, plus the ICU data file into
# assets/icu/ (libzim's full-text search needs it at runtime).
#
# The prebuilt libzim Android tarball is downloaded once and cached. Set FORCE=1
# to rebuild the shim.
set -e

LIBZIM_VERSION="9.7.0"
LIBZIM_TARBALL="libzim_android-arm64-${LIBZIM_VERSION}.tar.gz"
LIBZIM_URL="https://download.openzim.org/release/libzim/${LIBZIM_TARBALL}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/build"
JNI_DIR="$APP_DIR/android/app/src/main/jniLibs/arm64-v8a"
ASSET_ICU_DIR="$APP_DIR/assets/icu"
CACHE_DIR="${ZIMFFI_CACHE:-$HOME/.cache/cactus-ffi}"
LIBZIM_DIR="$CACHE_DIR/libzim_android-arm64-${LIBZIM_VERSION}"

ANDROID_PLATFORM=${ANDROID_PLATFORM:-android-24}
ABI="arm64-v8a"

# Resolve the NDK (same logic as native/build.sh).
if [ -z "$ANDROID_NDK_HOME" ]; then
  if [ -n "$ANDROID_NDK_LATEST_HOME" ]; then
    ANDROID_NDK_HOME="$ANDROID_NDK_LATEST_HOME"
  elif [ -n "$ANDROID_HOME" ]; then
    ANDROID_NDK_HOME=$(ls -d "$ANDROID_HOME/ndk/"* 2>/dev/null | sort -V | tail -1)
  elif [ -d "$HOME/Android/Sdk/ndk" ]; then
    ANDROID_NDK_HOME=$(ls -d "$HOME/Android/Sdk/ndk/"* 2>/dev/null | sort -V | tail -1)
  fi
fi
if [ -z "$ANDROID_NDK_HOME" ] || [ ! -d "$ANDROID_NDK_HOME" ]; then
  echo "Error: Android NDK not found. Set ANDROID_NDK_HOME." >&2
  exit 1
fi

# 1. Fetch + cache the prebuilt libzim Android tree.
if [ ! -d "$LIBZIM_DIR" ]; then
  echo "Downloading prebuilt libzim ${LIBZIM_VERSION} (arm64)…"
  mkdir -p "$CACHE_DIR"
  curl -sL -o "$CACHE_DIR/$LIBZIM_TARBALL" "$LIBZIM_URL"
  tar xzf "$CACHE_DIR/$LIBZIM_TARBALL" -C "$CACHE_DIR"
fi
LIBZIM_SO="$LIBZIM_DIR/lib/aarch64-linux-android/libzim.so"
ICU_DAT_SRC=$(find "$LIBZIM_DIR/share/icu" -name 'icudt*.dat' | head -1)

# 2. Compile the shim (incremental).
TOOLCHAIN="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
SHIM_BUILT="$BUILD_DIR/libzimffi.so"
if [ "${FORCE:-0}" = "1" ] || [ ! -f "$SHIM_BUILT" ] \
    || [ "$SCRIPT_DIR/zimffi.cpp" -nt "$SHIM_BUILT" ]; then
  echo "Building libzimffi.so…"
  cmake -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM="$ANDROID_PLATFORM" \
        -DCMAKE_BUILD_TYPE=Release \
        -DLIBZIM_DIR="$LIBZIM_DIR" \
        -S "$SCRIPT_DIR" -B "$BUILD_DIR" >/dev/null
  cmake --build "$BUILD_DIR" --config Release -j "$(nproc 2>/dev/null || echo 4)"
fi
[ -f "$SHIM_BUILT" ] || { echo "Error: libzimffi.so not built" >&2; exit 1; }

# 3. Install libs (stripped) + ICU data.
STRIP="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
LIBCPP=$(find "$ANDROID_NDK_HOME" -path '*aarch64-linux-android*' -name 'libc++_shared.so' | head -1)
mkdir -p "$JNI_DIR" "$ASSET_ICU_DIR"
install_so() { cp "$1" "$JNI_DIR/$(basename "$1")"; "$STRIP" "$JNI_DIR/$(basename "$1")" 2>/dev/null || true; }
install_so "$SHIM_BUILT"
install_so "$LIBZIM_SO"
install_so "$LIBCPP"
cp "$ICU_DAT_SRC" "$ASSET_ICU_DIR/$(basename "$ICU_DAT_SRC")"

echo "Installed into $JNI_DIR:"
ls -la "$JNI_DIR"/libzim*.so "$JNI_DIR"/libc++_shared.so
echo "ICU data: $ASSET_ICU_DIR/$(basename "$ICU_DAT_SRC")"
