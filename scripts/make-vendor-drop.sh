#!/bin/bash
# Copyright (C) 2026 Samaksh Kamboj
# SPDX-License-Identifier: Apache-2.0
# make-vendor-drop.sh — turn built module zips into a ROM-ready vendor-drop/:
# patched APKs (never stock/), matching lib/arm64 sets from the bundled
# stock bases, versions.json manifest, SHA256SUMS, optional .part chunks
# in vendor-tree split format.
#
# Usage:
#   ./make-vendor-drop.sh --out <dir> --tag <release-tag>
#       --app <name=YouTube> --module <zip> [--app <name> --module <zip> ...]
#       [--apk-name <file> ...] [--base-version <v> ...]
#       [--patch-rev <rev>] [--split] [--split-size 20m]
# Staged APK names default to <App>Patched.apk; pass --apk-name for
# release-style names (e.g. youtube-morphe-patched-v21.20.405-arm64-v8a.apk).
# The -patched- infix distinguishes these root builds from non-root assets.
# Example:
#   ./make-vendor-drop.sh --out vendor-drop --tag 20221113 \
#       --app YouTube --module youtube-morphe-module-v21.20.405-all.zip \
#       --app Music --module yt-music-morphe-module-v9.20.53-arm64-v8a.zip \
#       --patch-rev v1.22.0 --split
#
# versions.json shape (consumed by vendor update.sh + manager update center):
#   { "tag": ..., "patch_rev": ...,
#     "apps": { "<name>": { "base_version": ..., "module": <file>,
#                            "apk": <file>, "sha256": ... } } }
# Base versions come from --base-version (build provenance), falling back to
# the module file name when absent (manual runs).

set -euo pipefail

OUT=""
TAG=""
PATCH_REV="${PATCH_REV:-}"
SPLIT=0
SPLIT_SIZE="20m"
APPS=()
MODULES=()
BASES=()
APKNAMES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="${2:-}"; shift 2 ;;
        --tag) TAG="${2:-}"; shift 2 ;;
        --patch-rev) PATCH_REV="${2:-}"; shift 2 ;;
        --app) APPS+=("${2:-}"); shift 2 ;;
        --module) MODULES+=("${2:-}"); shift 2 ;;
        --base-version) BASES+=("${2:-}"); shift 2 ;;
        --apk-name) APKNAMES+=("${2:-}"); shift 2 ;;
        --split) SPLIT=1; shift ;;
        --split-size) SPLIT_SIZE="${2:-20m}"; shift 2 ;;
        --help|-h) sed -n '2,/^$/p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1 (try --help)"; exit 1 ;;
    esac
done

[ -n "$OUT" ] || { echo "[drop] --out is required"; exit 1; }
[ -n "$TAG" ] || { echo "[drop] --tag is required"; exit 1; }
[ "${#APPS[@]}" -gt 0 ] || { echo "[drop] at least one --app/--module pair is required"; exit 1; }
[ "${#APPS[@]}" -eq "${#MODULES[@]}" ] || { echo "[drop] --app/--module count mismatch"; exit 1; }

mkdir -p "$OUT"

# Reuses the exact selection semantics the vendor tree relies on:
# patched = largest APK outside stock/, libs = full set from bundled stock.
stage_one() {
    python3 - "$1" "$2" "$3" <<'EOF'
import zipfile, sys, os
mod_path, apk_out, lib_dir = sys.argv[1], sys.argv[2], sys.argv[3]
z = zipfile.ZipFile(mod_path)
cands = [(i.filename, i.file_size) for i in z.infolist()
         if i.filename.endswith('.apk') and 'stock' not in i.filename.lower()]
assert cands, f"no patched apk in {mod_path}"
src = max(cands, key=lambda x: x[1])[0]
print("staging:", src, "->", apk_out)
os.makedirs(os.path.dirname(apk_out), exist_ok=True)
with z.open(src) as s, open(apk_out, 'wb') as d:
    d.write(s.read())
stock = [(i.filename, i.file_size) for i in z.infolist()
         if i.filename.endswith('.apk') and 'stock' in i.filename.lower()]
assert stock, f"no stock apk in {mod_path}"
sfile = max(stock, key=lambda x: x[1])[0]
print("lib source:", sfile)
import io
inner = zipfile.ZipFile(io.BytesIO(z.read(sfile)))
names = [i.filename for i in inner.infolist()
         if i.filename.startswith('lib/arm64-v8a/') and i.filename.endswith('.so')]
import shutil
shutil.rmtree(lib_dir, ignore_errors=True)
os.makedirs(lib_dir, exist_ok=True)
for n in names:
    with inner.open(n) as s, open(os.path.join(lib_dir, n.split('/')[-1]), 'wb') as d:
        d.write(s.read())
print("libs:", len(names), "->", lib_dir)
EOF
}

MANIFEST_ENTRIES=""
STAGED_APKS=""

i=0
for app in "${APPS[@]}"; do
    mod="${MODULES[$i]}"
    base="${BASES[$i]:-}"
    apkname="${APKNAMES[$i]:-}"
    i=$((i + 1))
    echo "[drop] $app <= $mod"
    [ -n "$apkname" ] || apkname="${app}Patched.apk"
    apk="$OUT/$apkname"
    lib="$OUT/${app}/lib/arm64"
    stage_one "$mod" "$apk" "$lib"
    # Base version: explicit provenance first, module file name fallback.
    if [ -z "$base" ]; then
        base="$(basename "$mod" | grep -m1 -o 'v[0-9][0-9.]*' | head -n1 || true)"
        base="${base#v}"
    fi
    sha="$(sha256sum "$apk" | cut -d' ' -f1)"
    STAGED_APKS="$STAGED_APKS $(basename "$apk")"
    MANIFEST_ENTRIES="$MANIFEST_ENTRIES$(python3 -c "
import json,sys
print(json.dumps({sys.argv[1]: {'base_version': sys.argv[2], 'module': sys.argv[3], 'apk': sys.argv[4], 'sha256': sys.argv[5]}}))
" "$app" "$base" "$(basename "$mod")" "$(basename "$apk")" "$sha")"$'\n'
done

python3 - "$OUT" "$TAG" "$PATCH_REV" <<EOF
import json, sys
out, tag, prev = sys.argv[1], sys.argv[2], sys.argv[3]
apps = {}
for line in """$MANIFEST_ENTRIES""".splitlines():
    line = line.strip()
    if line:
        apps.update(json.loads(line))
with open(f"{out}/versions.json", "w") as f:
    json.dump({"tag": tag, "patch_rev": prev, "apps": apps}, f, indent=2)
print("wrote", f"{out}/versions.json")
EOF

# Checksums cover the staged APKs + manifest (lib dirs re-verify at ROM
# build time; explicit file list, never globs — names vary by caller).
# shellcheck disable=SC2086
(cd "$OUT" && sha256sum $STAGED_APKS versions.json > SHA256SUMS)
echo "[drop] wrote $OUT/SHA256SUMS"

if [ "$SPLIT" -eq 1 ]; then
    find "$OUT" -maxdepth 1 -type f -name "*.apk" | while read -r apk; do
        echo "[drop] splitting $(basename "$apk")"
        rm -f "$apk.part"*
        split -b "$SPLIT_SIZE" -d -a 3 "$apk" "$apk.part"
    done
fi

echo "[drop] done: $(ls "$OUT")"
