# Cactus Chat — Flutter example app

A minimal Flutter app that runs an LLM **fully on-device** through the Cactus
engine, producing an installable Android APK.

It bundles the native `libcactus.so` (arm64-v8a) and a pre-transpiled
`LFM2.5-350M` model. On first launch it unpacks the model to internal
storage, loads it, and then streams chat completions on a background isolate.

## How it works

- `lib/cactus.dart` — Dart FFI bindings to the Cactus C API (vendored copy of
  `flutter/cactus.dart`).
- `lib/inference_isolate.dart` — a worker isolate that owns the model pointer
  and runs `cactus_init` / `cactus_complete` (these block, so they must stay off
  the UI isolate).
- `lib/model_manager.dart` — unpacks the bundled model asset on first launch.
- `lib/main.dart` — the chat UI.
- `native/` — builds the **FFI** `libcactus.so` for Android. This is distinct
  from `android/build.sh`, which builds the JNI library for the Kotlin SDK and
  hides the C FFI symbols (`-Wl,--exclude-libs,ALL`) that Dart needs.

## Why the model must be transpiled first

Cactus models are loaded as a *transpiled bundle* — `config.txt` + `*.weights`
plus a `components/manifest.json` graph. The HuggingFace archives ship raw
weights only; the graph is produced by the host-side Python transpiler
(`python/cactus/transpile/`). The on-device engine **cannot** transpile, so a
ready-to-load bundle is produced on a host and shipped inside the APK.

## Building locally

```bash
# 1. Build the FFI native library into jniLibs (needs ANDROID_NDK_HOME)
bash native/build.sh

# 2. Produce the bundled model asset (needs the Cactus Python toolchain:
#    run `source ./setup` at the repo root first). One-time, host-side.
bash tools/build_model_asset.sh

# 3. Build / run
flutter build apk --release --target-platform android-arm64
flutter install   # or: adb install build/app/outputs/flutter-apk/app-release.apk
```

The model asset (`assets/model.zip`, ~200 MB) and the native `.so` are
gitignored. CI rebuilds the `.so` and fetches the model bundle from the GitHub
release before building the APK.

## Notes

- arm64-v8a only (the engine ships NEON kernels; there is no x86 build).
- The release APK is debug-signed so it installs directly — it is a demo, not a
  Play-Store artifact.
