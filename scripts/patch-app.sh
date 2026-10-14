#!/bin/bash
# Copyright (C) 2026 Samaksh Kamboj
# SPDX-License-Identifier: Apache-2.0
# patch-app.sh — patch one stock APK with the Morphe CLI (root recipe) and
# sign the result with OUR key. Proven recipe, do not freestyle it:
#   --mount (keep stock package name for mount-over-stock installs)
#   -d "GmsCore support"      (non-root spoof; root uses real GMS/microG)
#   -d "Change package name"  (root must keep the stock name)
#   --striplibs (default arm64-v8a)
#   --unsigned at the CLI step, then explicit sign below so the key is
#   always ours and never silently absent.
#
# Signing: apksigner when present, else jarsigner (v1, sufficient for
# PackageManager), else hard fail — shipping unsigned is a silent
# install-time break. MORPHE_ALLOW_UNSIGNED=1 skips with a loud warning
# (local testing only, never CI).
#
# Keystore: --keystore (or MORPHE_KEYSTORE) with pass/alias opts. Absent:
# keytool generates an ephemeral one and warns that updates signed later
# with another key will signature-clash on dirty flashes.
#
# Usage:
#   ./patch-app.sh --app music --stock stock.apk --out patched.apk
#     --workdir work/ --cli-rev v1.18.1 --patches-rev v1.47.0
#     [--keystore ks.jks --storepass x --alias morphe --keypass x]
#     [--extra-disable "Some patch"] [--striplibs arm64-v8a,x86]
#     [--result-json result.json]
# Env: JAVA_TOOL_OPTIONS=-Xmx10g (heap; callers set it, YouTube is hungry).

set -euo pipefail

APP=""; STOCK=""; OUT=""; WORKDIR=""; CLI_REV=""; PATCHES_REV=""
KEYSTORE="${MORPHE_KEYSTORE:-}"; STOREPASS="${MORPHE_STOREPASS:-}"
KEYALIAS="${MORPHE_KEYALIAS:-morphe}"; KEYPASS="${MORPHE_KEYPASS:-}"
STRIPLIBS="arm64-v8a"; RESULT_JSON=""; EXTRA_DISABLE=()

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="${2:-}"; shift 2 ;;
        --stock) STOCK="${2:-}"; shift 2 ;;
        --out) OUT="${2:-}"; shift 2 ;;
        --workdir) WORKDIR="${2:-}"; shift 2 ;;
        --cli-rev) CLI_REV="${2:-}"; shift 2 ;;
        --patches-rev) PATCHES_REV="${2:-}"; shift 2 ;;
        --keystore) KEYSTORE="${2:-}"; shift 2 ;;
        --storepass) STOREPASS="${2:-}"; shift 2 ;;
        --alias) KEYALIAS="${2:-}"; shift 2 ;;
        --keypass) KEYPASS="${2:-}"; shift 2 ;;
        --striplibs) STRIPLIBS="${2:-}"; shift 2 ;;
        --result-json) RESULT_JSON="${2:-}"; shift 2 ;;
        --extra-disable) EXTRA_DISABLE+=("${2:-}"); shift 2 ;;
        --help|-h) sed -n '2,/^$/p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1 (try --help)"; exit 1 ;;
    esac
done

[ -n "$APP" ] && [ -n "$STOCK" ] && [ -n "$OUT" ] && [ -n "$WORKDIR" ] \
    && [ -n "$CLI_REV" ] && [ -n "$PATCHES_REV" ] \
    || { echo "[patch] --app/--stock/--out/--workdir/--cli-rev/--patches-rev required"; exit 1; }
[ -f "$STOCK" ] || { echo "[patch] stock not found: $STOCK"; exit 1; }
mkdir -p "$WORKDIR"
[ -z "$RESULT_JSON" ] && RESULT_JSON="$WORKDIR/result-$APP.json"

gh_asset() {
    # $1 = owner/repo, $2 = tag, $3 = grep pattern for the asset name
    curl -fsSL "https://api.github.com/repos/$1/releases/tags/$2" \
        | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4 \
        | grep -E "$3" | head -n1
}

echo "[patch] resolving morphe-cli $CLI_REV ..."
CLI_JAR="$WORKDIR/morphe-cli.jar"
if [ ! -s "$CLI_JAR" ]; then
    URL="$(gh_asset MorpheApp/morphe-cli "$CLI_REV" '\-all\.jar$')"
    [ -n "$URL" ] || { echo "[patch] CLI jar not found for $CLI_REV"; exit 1; }
    curl -fL -o "$CLI_JAR" "$URL"
fi
echo "[patch] resolving patches $PATCHES_REV ..."
MPP="$WORKDIR/patches.mpp"
if [ ! -s "$MPP" ]; then
    URL="$(gh_asset MorpheApp/morphe-patches "$PATCHES_REV" '\.mpp$')"
    [ -n "$URL" ] || { echo "[patch] patches mpp not found for $PATCHES_REV"; exit 1; }
    curl -fL -o "$MPP" "$URL"
fi

if [ -z "$KEYSTORE" ]; then
    echo "[patch] WARNING: no keystore — generating EPHEMERAL key (updates signed later with another key will clash; use a stable keystore in CI)."
    KEYSTORE="$WORKDIR/ephemeral.jks"
    STOREPASS="${STOREPASS:-morphe-ephemeral}"
    KEYPASS="${KEYPASS:-$STOREPASS}"
    if [ ! -f "$KEYSTORE" ]; then
        keytool -genkeypair -keystore "$KEYSTORE" -alias "$KEYALIAS" \
            -keyalg RSA -keysize 2048 -validity 10950 \
            -storepass "$STOREPASS" -keypass "$KEYPASS" \
            -dname "CN=Morphe Builder Ephemeral" >/dev/null
    fi
fi
[ -n "$STOREPASS" ] || { echo "[patch] keystore password required (--storepass or MORPHE_STOREPASS)"; exit 1; }
KEYPASS="${KEYPASS:-$STOREPASS}"

DISABLE_ARGS=(-d "GmsCore support" -d "Change package name")
for p in "${EXTRA_DISABLE[@]:-}"; do
    [ -n "$p" ] && DISABLE_ARGS+=(-d "$p")
done

echo "[patch] patching $APP (mount recipe, strip $STRIPLIBS) ..."
# shellcheck disable=SC2068
java -jar "$CLI_JAR" patch -p "$MPP" --mount "${DISABLE_ARGS[@]}" \
    --striplibs "$STRIPLIBS" --unsigned \
    -o "$OUT" -r "$RESULT_JSON" "$STOCK"

python3 - "$RESULT_JSON" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
steps = {s["step"]: s["success"] for s in r.get("patchingSteps", [])}
failed = r.get("failedPatches", [])
print("package:", r.get("packageName"), r.get("packageVersion"))
print("steps:", steps, "failed:", failed)
if not all(steps.values()) or failed:
    sys.exit("patch reported failures")
EOF

sign_apk() {
    # $1 = unsigned in, $2 = signed out. apksigner preferred, jarsigner
    # fallback, hard fail otherwise (unsigned must never ship silently).
    if command -v apksigner >/dev/null 2>&1; then
        echo "[patch] signing with apksigner"
        apksigner sign --ks "$KEYSTORE" --ks-pass:pass:"$STOREPASS" \
            --key-pass:pass:"$KEYPASS" --out "$2" "$1"
    elif command -v jarsigner >/dev/null 2>&1; then
        echo "[patch] signing with jarsigner (v1)"
        jarsigner -keystore "$KEYSTORE" -storepass "$STOREPASS" \
            -keypass "$KEYPASS" -signedjar "$2" "$1" "$KEYALIAS" >/dev/null
    else
        echo "[patch] ERROR: neither apksigner nor jarsigner found — refusing to ship unsigned."
        return 1
    fi
}

if [ -n "${MORPHE_ALLOW_UNSIGNED:-}" ]; then
    echo "[patch] WARNING: MORPHE_ALLOW_UNSIGNED=1 — shipping UNSIGNED (local testing only)."
else
    sign_apk "$OUT" "$OUT.signed" && mv -f "$OUT.signed" "$OUT"
fi

echo "[patch] done: $OUT ($(du -h "$OUT" | cut -f1))"
