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

Patching itself runs through the upstream template machinery (its build job
is the one integration point, marked `TODO(fork wiring)` in the workflow):
this repo owns everything downstream — selection, QA, ROM-shaped outputs,
manifest, publishing. Configure sources and pins in `config.toml`.

## Channels

- `stable` — pinned base APK + patch revs, reproducible, for ROM CI.
- `beta` — floating latest, for testing. Promote to stable by pinning.

## License

Apache-2.0, see LICENSE. Patch sources and base APKs belong to their
respective owners and are fetched at build time, never committed.
