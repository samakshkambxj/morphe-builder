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
#                [--min-stock-libs N]
# A module passes when the patched build is genuine AND a usable native lib
# source exists anywhere: our own patch output carries its full lib set
# (self-contained), while libless-over-stock modules carry near-zero libs and rely
# on the bundled stock base. Either shape passes; libless-patched AND
# missing/thin-stock fails (that combination dies at startup with
# UnsatisfiedLinkError — the exact outage this gate exists to prevent).
# Example:
#   ./qa-gate.sh --module youtube-morphe-module-v21.20.405-all.zip \
#       --markers app/morphe,SponsorBlock --max-patched-libs 2 --min-stock-libs 10

set -euo pipefail

MODULE=""
MARKERS=""
MIN_STOCK_LIBS=10

while [ $# -gt 0 ]; do
    case "$1" in
        --module) MODULE="${2:-}"; shift 2 ;;
        --markers) MARKERS="${2:-}"; shift 2 ;;
        --min-stock-libs) MIN_STOCK_LIBS="${2:-10}"; shift 2 ;;
        --max-patched-libs) echo "[qa] NOTE: --max-patched-libs is obsolete (lib shape varies by producer)"; shift 2 ;;
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

# 3. Native lib source must exist SOMEWHERE. Producers differ: our own patch
# output is self-contained (full lib set inside the patched build) while
# External libless-over-stock modules ship near-libless patched builds over a full stock
# base. Either shape stages fine downstream; libless-patched plus
# missing/thin-stock is a guaranteed runtime UnsatisfiedLinkError.
PLIBS="$(python3 -c "
import zipfile, sys, io
z = zipfile.ZipFile(sys.argv[1])
inner = zipfile.ZipFile(io.BytesIO(z.read(sys.argv[2])))
print(sum(1 for i in inner.infolist() if i.filename.endswith('.so')))
" "$MODULE" "$PATCHED")"
echo "[qa] patched lib count: $PLIBS"

# 4. Bundled stock base: preferred lib source (version-identical full set).
STOCK="$(python3 -c "
import zipfile, sys
z = zipfile.ZipFile(sys.argv[1])
cands = [(i.filename, i.file_size) for i in z.infolist()
         if i.filename.endswith('.apk') and 'stock' in i.filename.lower()]
print(max(cands, key=lambda x: x[1])[0] if cands else '')
" "$MODULE")"
SLIBS=0
if [ -n "$STOCK" ]; then
    SLIBS="$(python3 -c "
import zipfile, sys, io
z = zipfile.ZipFile(sys.argv[1])
inner = zipfile.ZipFile(io.BytesIO(z.read(sys.argv[2])))
print(sum(1 for i in inner.infolist() if i.filename.startswith('lib/arm64-v8a/') and i.filename.endswith('.so')))
" "$MODULE" "$STOCK")"
    echo "[qa] stock lib source: $STOCK ($SLIBS arm64 libs)"
fi

if [ "$PLIBS" -gt 2 ]; then
    echo "[qa] lib source: patched build itself (self-contained)"
elif [ -n "$STOCK" ] && [ "$SLIBS" -ge "$MIN_STOCK_LIBS" ]; then
    echo "[qa] lib source: bundled stock base"
else
    fail "no usable native lib source (patched libless AND no full stock base)"
fi

echo "[qa] PASS: $MODULE"
