# Publishing Eva to Zapstore

[Zapstore](https://zapstore.dev) is a permissionless app store built on Nostr.
It has no free-software-license requirement (unlike F-Droid.org), takes the APK
straight from this repo's GitHub releases, and reuses the Fastlane listing under
`flutter/example/fastlane/metadata/android/en-US/`.

## What's prepared

- [`zapstore.yaml`](../../zapstore.yaml) in the repo root — points at this repo,
  pulls the APK from the GitHub release and metadata from GitHub. **Validated**
  with `zsp publish --check zapstore.yaml` → `{"package_id":"radio.geogram.eva"}`.
- The store listing (title, descriptions, changelog, 512px icon, screenshots)
  reused from the F-Droid prep.

## You need

- The `zsp` CLI (installed here at `~/go/bin/zsp`; or `go install
  github.com/zapstore/zsp@latest`, or download from
  <https://github.com/zapstore/zsp/releases>).
- Your **Nostr private key** (`nsec1…`) — used to sign the Nostr events.
- The **APK signing keystore** (`~/.keys/eva-release.keystore`, the same JKS the
  release CI signs with) — linked once to your Nostr identity so users can trust
  updates come from you. zsp accepts `.jks` / `.p12` / `.pem`.

## Steps

1. **Set your pubkey.** Edit `zapstore.yaml` and replace `REPLACE_WITH_YOUR_NPUB`
   with your `npub…`. Commit it.

2. **Publish** (signs the Nostr events with your key; never commit the nsec):

   ```bash
   export SIGN_WITH=nsec1...                 # or bunker://… for CI
   export GITHUB_TOKEN=$(gh auth token)      # avoids GitHub rate limits
   ~/go/bin/zsp publish zapstore.yaml        # or: ~/go/bin/zsp publish --wizard
   ```

   The first run links your signing certificate to your Nostr identity and the
   relay whitelists your pubkey (after fetching this `zapstore.yaml` and checking
   it matches). Subsequent releases just re-run the publish command.

3. **New releases.** After each GitHub release (e.g. `v2.x`), re-run the publish
   command — zsp picks up the new release APK and metadata automatically.

## Notes

- Source is published as-is from GitHub (`repository:`); Zapstore does not impose
  a license check, so the current Cactus license is not a blocker here.
- Relays default to `wss://relay.zapstore.dev` and the binary CDN to
  `https://cdn.zapstore.dev`; override with `RELAY_URLS` / `BLOSSOM_URL`.
- Run `zsp publish --check zapstore.yaml` any time to confirm the config still
  resolves the arm64 APK (no key needed).
