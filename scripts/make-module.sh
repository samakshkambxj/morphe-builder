#!/bin/bash
# Copyright (C) 2026 Samaksh Kamboj
# SPDX-License-Identifier: Apache-2.0
# make-module.sh — assemble a Magisk/KernelSU-installable module zip from a
# patched APK + its pristine stock base. Contract (consumed by qa-gate.sh
# and the vendor-drop assembler, do not freelance it):
#   base.apk        patched build (mountable, stock package name)
#   stock/base.apk  pristine stock base (version checks, lib staging source)
#   module.prop / customize.sh / uninstall.sh
# The module installs as a skeleton carrier for those files; Magisk-direct
# mounting behavior beyond that is explicitly out of scope for v1.
#
# Usage:
#   ./make-module.sh --app YouTube --package com.google.android.youtube
#     --version 21.20.405 --patched patched.apk --stock stock.apk
#     --out youtube-module.zip [--workdir work/]

set -euo pipefail

APP=""; PKG=""; VER=""; PATCHED=""; STOCK=""; OUT=""; WORKDIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="${2:-}"; shift 2 ;;
        --package) PKG="${2:-}"; shift 2 ;;
        --version) VER="${2:-}"; shift 2 ;;
        --patched) PATCHED="${2:-}"; shift 2 ;;
        --stock) STOCK="${2:-}"; shift 2 ;;
        --out) OUT="${2:-}"; shift 2 ;;
        --workdir) WORKDIR="${2:-}"; shift 2 ;;
        --help|-h) sed -n '2,/^$/p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1 (try --help)"; exit 1 ;;
    esac
done

[ -n "$APP" ] && [ -n "$PKG" ] && [ -n "$VER" ] && [ -n "$PATCHED" ] \
    && [ -n "$STOCK" ] && [ -n "$OUT" ] \
    || { echo "[module] --app/--package/--version/--patched/--stock/--out required"; exit 1; }
[ -f "$PATCHED" ] || { echo "[module] patched not found: $PATCHED"; exit 1; }
[ -f "$STOCK" ] || { echo "[module] stock not found: $STOCK"; exit 1; }
[ -z "$WORKDIR" ] && WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/morphe-module.XXXXXX")"
ID="morphe-$(echo "$APP" | tr '[:upper:]' '[:lower:]')"
case "$ID" in
    morphe-youtube) DISPNAME="YouTube" ;;
    morphe-music) DISPNAME="YT Music" ;;
    morphe-reddit) DISPNAME="Reddit" ;;
    *) DISPNAME="$(echo "$APP" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')" ;;
esac
VCODE="$(date -u +%Y%m%d)"

STAGE="$WORKDIR/stage-$ID"
rm -rf "$STAGE"
mkdir -p "$STAGE/stock"
cp -f "$PATCHED" "$STAGE/base.apk"
cp -f "$STOCK" "$STAGE/stock/base.apk"

cat > "$STAGE/module.prop" <<EOF
id=$ID
name=Morphe $DISPNAME
version=$VER
versionCode=$VCODE
author=morphe-builder
description=Root module: patched $DISPNAME $VER over stock ($PKG). No MicroG needed.
EOF

cat > "$STAGE/customize.sh" <<'EOF'
#!/system/bin/sh
# Carrier module: base.apk (patched) + stock/base.apk (pristine stock).
# Vendor trees and ROM tooling consume these directly; Magisk-direct
# mounting beyond file delivery is out of scope for this module revision.
ui_print "- Morphe module staged: base.apk + stock/base.apk"
EOF

cat > "$STAGE/uninstall.sh" <<'EOF'
#!/system/bin/sh
# Nothing persistent to clean: no boot scripts, no data files.
EOF

rm -f "$OUT"
OUTDIR="$(dirname "$OUT")"
mkdir -p "$OUTDIR" || { echo "[module] cannot create output dir: $OUTDIR"; exit 1; }
OUT_ABS="$(cd "$OUTDIR" && pwd)/$(basename "$OUT")"
(cd "$STAGE" && zip -9 -qr "$OUT_ABS" base.apk stock module.prop customize.sh uninstall.sh)
echo "[module] wrote $OUT_ABS ($(du -h "$OUT_ABS" | cut -f1))"
unzip -l "$OUT_ABS" | tail -n +4 | head -n -2
