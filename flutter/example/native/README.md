# Native FFI library (`libcactus.so`)

`build.sh` cross-compiles the Cactus engine + usearch into a single arm64-v8a
`libcactus.so` that exports the C FFI symbols the Dart bindings use
(`lib/cactus.dart`, `lib/usearch.dart`). It is installed into
`android/app/src/main/jniLibs/arm64-v8a/`, where Gradle simply **packages** it —
there is no `externalNativeBuild`, so a normal `flutter build` / `flutter run`
never recompiles native code.

It cross-compiles fine on x86 (CI builds it on `ubuntu-24.04`); the NDK targets
arm64 regardless of host. No ARM machine is required.

## Compile once, then iterate fast

The engine is the expensive part to compile, so `build.sh` is content-addressed.
It hashes every native input (CMakeLists, `usearch/`, and the engine source —
committed *and* local edits) and:

1. **skips instantly** if the installed `.so` already matches that hash;
2. **restores from a machine-level cache** (`~/.cache/cactus-ffi`) if that hash
   was built here before — so a fresh checkout or a cleaned tree does **not**
   recompile the engine (and doesn't even need the NDK);
3. otherwise **compiles** (incrementally if `native/build/` is warm) and records
   the result in both `jniLibs/` and the cache.

Measured: up-to-date skip ~0.02 s; cache restore ~0.07 s; a real native-source
change triggers a rebuild.

### Typical loop

A Gradle hook (`ensureNativeFfi` in `android/app/build.gradle.kts`, wired into
`preBuild`) runs this script automatically before the app is assembled, so you
normally never invoke it by hand — just build/run as usual:

```bash
flutter run            # hot reload (r) / hot restart (R) for Dart-only changes
flutter build apk      # the hook ensures the .so (instant when current)
flutter test integration_test/rag_device_test.dart -d <deviceId>
```

The hook is instant on a cache hit and doesn't need the NDK; it only compiles
(needing the NDK, which it locates via the Android SDK) when native sources
actually changed. Run `bash native/build.sh` directly if you want to build the
library on its own.

`flutter clean` removes `build/` but **not** `jniLibs/`, so the installed `.so`
survives it. Even a full `git clean` only costs one cache restore (~0.1 s) as
long as the same source version was built on this machine before.

### Flags

- `FORCE=1 bash native/build.sh` — always recompile (e.g. after an NDK upgrade,
  which is intentionally not part of the hash).
- `CACTUS_FFI_CACHE=/path bash native/build.sh` — override the cache directory
  (default `~/.cache/cactus-ffi`).
- `ANDROID_NDK_HOME=/path` — only needed when an actual compile happens; cache
  hits don't require it.

## When you must recompile

Only changes under the hashed inputs trigger a rebuild: `native/CMakeLists.txt`,
`native/usearch/`, or the engine sources (`cactus/`, `cactus-engine/`). Editing
Dart never does.
