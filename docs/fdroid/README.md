# Releasing Eva on F-Droid

This document covers what's prepared, the **blockers** for the official
F-Droid.org repository, and the two release paths.

## What's prepared

- **Store listing metadata** (Fastlane layout, also used by IzzyOnDroid /
  Accrescent / Play): `flutter/example/fastlane/metadata/android/en-US/`
  — `title.txt`, `short_description.txt`, `full_description.txt`,
  `changelogs/<versionCode>.txt`, `images/icon.png` (512×512) and eight
  `images/phoneScreenshots/`.
- App id (F-Droid package name): **`radio.geogram.eva`**.

## ⚠️ Blockers for the official F-Droid.org repo

F-Droid.org only ships apps that are **free software**, **build from source with
no network access**, and contain **no proprietary dependencies or prebuilt
binaries**. Eva currently fails several of these:

1. **License is not FOSS (showstopper).** `LICENSE` is the Cactus Compute
   source-available license: it forbids commercial use above a revenue/funding
   threshold and requires a paid commercial license otherwise. That field-of-use
   restriction is **not an FSF-free / OSI-approved license**, so F-Droid.org
   cannot include Eva at all. *Fix:* the engine must be relicensed under a free
   license (with Cactus Compute), or Eva must move to a FOSS inference engine.
2. **Proprietary dependency: Syncfusion.** `syncfusion_flutter_pdf` /
   `syncfusion_flutter_pdfviewer` are under the proprietary Syncfusion Community
   License. *Fix:* replace with a FOSS PDF renderer (e.g. `pdfrx`/`pdfium`,
   Apache/BSD) for the PDF viewer.
3. **Build-time binary download.** `native_zim/build_zim.sh` downloads a
   **prebuilt** `libzim` from openzim.org during the Gradle build. F-Droid builds
   **offline** and rejects fetching/bundling prebuilt binaries. *Fix:* build
   libzim from source in the recipe, or drop the offline-Wikipedia feature from
   the F-Droid build flavor.
4. **Prebuilt native libs via plugins.** `sherpa_onnx` (and the Cactus build)
   ship/produce native `.so`s; F-Droid needs them built from source in the
   recipe (the Cactus engine *is* in-tree and built by `native/build.sh`, which
   is good; verify it builds with no network).
5. **versionCode never increments.** `pubspec.yaml` is pinned at `1.0.0+1`, so
   every release is versionCode **1**. F-Droid needs a strictly increasing
   versionCode per release. *Fix:* derive versionName/Code from the release tag.
6. **Runtime downloads (anti-feature, not a blocker).** Models, Wikipedia
   editions, voice and lyrics are fetched at runtime from the internet — F-Droid
   would tag this `NonFreeNet` / `NonFreeAssets` and disclose it.

Until at least #1–#3 and #5 are resolved, **submission to F-Droid.org is not
possible.**

## Path A — official F-Droid.org (after the blockers are fixed)

Submit a metadata recipe to <https://gitlab.com/fdroid/fdroiddata>. A draft is in
[`radio.geogram.eva.yml`](radio.geogram.eva.yml) — it points at this repo, builds
`flutter/example` for arm64, and reads the Fastlane metadata above. It still
needs the blockers resolved (free license, no Syncfusion, no build-time
download, incrementing versionCode) before it will pass `fdroid build` /
`fdroid lint`.

## Path B — self-hosted F-Droid repository (works today)

You can run **your own** F-Droid repo, which has no license restriction and can
serve the existing signed APK. Users add the repo URL (or scan a QR) in the
F-Droid client.

```bash
pip install fdroidserver        # or: apt install fdroidserver
mkdir eva-fdroid && cd eva-fdroid
fdroid init                     # creates config.yml + a signing key
mkdir -p repo
# drop the released APK in:
cp /path/to/eva-android-arm64-v8a.apk repo/
fdroid update --create-metadata # builds the index, picks up metadata/icon
# publish the ./repo folder on any static host (e.g. GitHub Pages)
```

Point the per-app metadata at the Fastlane listing and screenshots prepared
above. This is the pragmatic way to "release on F-Droid" now, without
relicensing — it just isn't the curated F-Droid.org catalog.

## Recommendation

- **Now:** publish a **self-hosted F-Droid repo** (Path B) serving the v2.x APK,
  using the listing metadata in this repo.
- **For F-Droid.org (Path A):** decide on the license first (it's the
  showstopper); then swap Syncfusion for a FOSS PDF lib, make the libzim build
  source-only/offline, and derive an incrementing versionCode from the tag.
