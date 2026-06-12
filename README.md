# Eva

Eva is a fully offline AI assistant for Android. Everything runs on the phone:
the language model, speech recognition, text-to-speech, and document search.
No account, no cloud, no data leaving the device.

Download the latest APK: https://github.com/geograms/eva/releases/latest
(or run `binary/get-latest-apk.sh`).

## Features

- On-device chat with selectable models (LFM2.5, Qwen3, vision models),
  downloaded on demand or sideloaded from a folder.
- Digital assistant integration: set Eva as the phone's assistant and invoke it
  with a power-button hold — it listens, answers, and speaks the reply.
- Voice in/out: offline streaming speech-to-text (English) or the phone's
  recognizer (many languages), plus spoken replies.
- Ask questions about your documents (PDF/text): hybrid retrieval over a
  sharded on-device vector index (usearch, int8) fused with full-text search,
  built for very large archives. The index can live on an SD card and survive
  reinstalls.
- Vision: attach a photo and ask about it (with a vision model selected).
- Persistent chat history with a conversation drawer.

## Repository layout

- `flutter/example/` — the Eva Flutter app (`lib/`), its native FFI library
  build (`native/`, see its README for the fast content-addressed build), and
  the on-device integration tests.
- `cactus/`, `cactus-engine/`, `cactus-graph/`, `cactus-kernels/` — the Cactus
  inference engine sources compiled into `libcactus.so` (see LICENSE).
- `python/` — the host-side transpiler that converts HuggingFace models into
  loadable bundles (used by CI; the phone only loads pre-transpiled bundles).
- `.github/workflows/android-release.yml` — CI: transpiles missing model
  bundles and publishes the APK to the GitHub release.
- `binary/` — convenience script to fetch the latest released APK.

## Building

```bash
cd flutter/example
flutter build apk --release --target-platform android-arm64
```

The native library is built (or restored from a local cache) automatically by a
Gradle hook; an Android NDK is only needed when engine sources actually change.

## Credits

Built on the Cactus inference engine (Cactus Compute, Inc. — see LICENSE).
Eva is maintained by Geogram.
