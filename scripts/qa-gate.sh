#!/bin/bash
# Copyright (C) 2026 Samaksh Kamboj
# SPDX-License-Identifier: Apache-2.0
# qa-gate.sh — post-build assertions on one module zip. Fails loudly on
# structural problems so upstream layout changes break the BUILD instead of
# shipping wrong files silently (a largest-file rule once staged pristine
# stock as "patched" and flashed it to devices).
#
# Layout contract enforced:
#   base.apk (zip root)        -> mountable PATCHED build, carries patch
#                                dex markers, carries (near-)zero .so files
#   stock/base.apk             -> pristine STOCK base, full arm64 lib set
#
# Usage:
#   ./qa-gate.sh --module <zip> --markers <csv-substrings-required-in-dex>
#                [--max-patched-libs N] [--min-stock-libs N]
# Example:
#   ./qa-gate.sh --module youtube-morphe-module-v21.20.405-all.zip \
#       --markers app/morphe,SponsorBlock --max-patched-libs 2 --min-stock-libs 10

set -euo pipefail

MODULE=""
MARKERS=""
MAX_PATCHED_LIBS=2
MIN_STOCK_LIBS=10

while [ $# -gt 0 ]; do
    case "$1" in
        --module) MODULE="${2:-}"; shift 2 ;;
        --markers) MARKERS="${2:-}"; shift 2 ;;
        --max-patched-libs) MAX_PATCHED_LIBS="${2:-2}"; shift 2 ;;
        --min-stock-libs) MIN_STOCK_LIBS="${2:-10}"; shift 2 ;;
        --help|-h) sed -n '2,/^$/p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1 (try --help)"; exit 1 ;;
    esac
done

[ -n "$MODULE" ] || { echo "[qa] --module is required"; exit 1; }
[ -f "$MODULE" ] || { echo "[qa] not found: $MODULE"; exit 1; }

fail() { echo "[qa] FAIL: $*"; exit 1; }

echo "[qa] gating $MODULE"

# 1. Patched candidate: largest APK outside stock/.
PATCHED="$(python3 -c "
import zipfile, sys
z = zipfile.ZipFile(sys.argv[1])
apks = [(i.filename, i.file_size) for i in z.infolist()
        if i.filename.endswith('.apk') and 'stock' not in i.filename.lower()]
print(max(apks, key=lambda x: x[1])[0] if apks else '')
" "$MODULE")"
[ -n "$PATCHED" ] || fail "no patched APK (outside stock/) in $MODULE"
echo "[qa] patched candidate: $PATCHED"

# 2. Patch markers must appear in its dex (proves it is patched, not stock).
if [ -n "$MARKERS" ]; then
    IFS=',' read -ra WANT <<< "$MARKERS"
    for m in "${WANT[@]}"; do
        if unzip -p "$MODULE" "$PATCHED" 2>/dev/null | python3 -c "
import zipfile, sys, io
z = zipfile.ZipFile(io.BytesIO(sys.stdin.buffer.read()))
blob = b''.join(z.read(n) for n in z.namelist() if n.endswith('.dex'))
sys.exit(0 if sys.argv[1].encode() in blob else 1)
" "$m"; then
            echo "[qa] marker ok: $m"
        else
            fail "marker '$m' absent from $PATCHED dex (stock shipped as patched?)"
        fi
    done
fi

# 3. Patched build must be (near-)libless: it resolves .so from beside the
# installed app at runtime. A lib-full 'patched' build means the module
# layout changed and lib staging assumptions need review.
PLIBS="$(python3 -c "
import zipfile, sys, io
z = zipfile.ZipFile(sys.argv[1])
inner = zipfile.ZipFile(io.BytesIO(z.read(sys.argv[2])))
print(sum(1 for i in inner.infolist() if i.filename.endswith('.so')))
" "$MODULE" "$PATCHED")"
echo "[qa] patched lib count: $PLIBS (max $MAX_PATCHED_LIBS)"
[ "$PLIBS" -le "$MAX_PATCHED_LIBS" ] || fail "$PATCHED carries $PLIBS .so files — layout changed, review lib staging"

# 4. Stock base must exist with a full arm64 lib set (lib staging source).
STOCK="$(python3 -c "
import zipfile, sys
z = zipfile.ZipFile(sys.argv[1])
cands = [(i.filename, i.file_size) for i in z.infolist()
         if i.filename.endswith('.apk') and 'stock' in i.filename.lower()]
print(max(cands, key=lambda x: x[1])[0] if cands else '')
" "$MODULE")"
[ -n "$STOCK" ] || fail "no stock APK (under stock/) in $MODULE — lib staging has no source"
SLIBS="$(python3 -c "
import zipfile, sys, io
z = zipfile.ZipFile(sys.argv[1])
inner = zipfile.ZipFile(io.BytesIO(z.read(sys.argv[2])))
print(sum(1 for i in inner.infolist() if i.filename.startswith('lib/arm64-v8a/') and i.filename.endswith('.so')))
" "$MODULE" "$STOCK")"
echo "[qa] stock lib source: $STOCK ($SLIBS arm64 libs, min $MIN_STOCK_LIBS)"
[ "$SLIBS" -ge "$MIN_STOCK_LIBS" ] || fail "stock base has only $SLIBS arm64 libs — not a usable lib source"

echo "[qa] PASS: $MODULE"
