<!-- Copyright (C) 2026 Samaksh Kamboj. SPDX-License-Identifier: Apache-2.0 -->
# morphe-builder — ROM-first patched-app builder

Automated builder producing **root Magisk/KernelSU modules** for Morphe-patched
YouTube, YouTube Music and Reddit — plus, unlike generic builders, release
artifacts shaped for direct ROM consumption:

- `*-module-*.zip` — root modules (stock package names, mount over stock)
- `vendor-drop/` — `YTPatched.apk` / `YTMusicPatched.apk` / `RedditPatched.apk`,
  matching `lib/arm64` sets, `versions.json` manifest, `SHA256SUMS`,
  optional `.part` chunks in vendor-tree split format
- `versions.json` — single source of truth per release: app → base version,
  patch rev, artifact URLs, checksums. Consumed by `vendor/morphe`
  `update.sh` and the MorpheManager update center instead of scraping the
  GitHub API.

Every module passes `scripts/qa-gate.sh` before publish: patched-vs-stock
identity (dex patch markers), mountable build outside `stock/`, full lib
set inside the bundled stock base. Upstream layout changes break the build
loudly instead of shipping wrong files silently.

## Layout

```
config.toml                  # what to build: sources, apps, base pins, channels
scripts/qa-gate.sh           # post-build assertions on module zips
scripts/make-vendor-drop.sh  # module zips -> ROM-ready vendor-drop/ + manifest
.github/workflows/build.yml  # matrix build: patch -> QA -> vendor-drop -> release
```

## Patch execution

From-source throughout: stock bases are fetched from the APKMirror pins in
`config.toml` (`scripts/fetch-stock.py`: monolithic-first scoring, then
structural validation — root manifest, dex, minimum arm64 lib set — walking
candidates until one passes). Split-bundle repacks are rejected outright:
their nested `base.apk` carries zero native libs and the patcher NPEs on
manifest-less input. When no APKMirror variant validates (recent Reddit),
the stock base is seeded from the upstream builder's module instead —
same pristine Google bytes, loudly logged.

Signing key: set `MORPHE_KEYSTORE_BASE64` (+ `MORPHE_STOREPASS`,
`MORPHE_KEYPASS`) repo secrets and CI uses the stable key; without them
the run generates an ephemeral key and says so loudly (fine for PR
testing, wrong for releases — dirty flashes would signature-clash).

## Channels

- `stable` — pinned base APK + patch revs, reproducible, for ROM CI.
- `beta` — floating latest, for testing. Promote to stable by pinning.

## Automation

Base APKs are **fixed** via `config.toml` pins: every build is hermetic
and reproducible, and advancement is a pin-bump PR, never a floating
re-download. The daily schedule runs `scripts/check-updates.py`, which
compares pins against **our last release manifest** (build only what is
unreleased) and separately reports **live drift** (promotion signal).
Pushes touching config/scripts/workflows build immediately, so merging
a pin bump releases it. Manual dispatch can force.

## License

Apache-2.0, see LICENSE. Patch sources and base APKs belong to their
respective owners and are fetched at build time, never committed.
