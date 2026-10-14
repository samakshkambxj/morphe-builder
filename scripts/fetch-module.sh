#!/bin/bash
# Copyright (C) 2026 Samaksh Kamboj
# SPDX-License-Identifier: Apache-2.0
# fetch-module.sh — download one app's module zip from the upstream builder
# releases into a normalized path. Interim patch step: until from-source
# patching is wired, the pipeline curates upstream modules (QA-gated and
# repackaged downstream) instead of pretending to patch.
#
# The builder rotates tag names across daily runs and the newest release
# does not always carry every app, so releases are scanned newest-first
# for the first tag holding this app's module.
#
# Usage:
#   ./fetch-module.sh --app <youtube|music|reddit> --out <dir> [--repo <owner/repo>]
# Output: <out>/<app>-module.zip

set -euo pipefail

APP=""
OUT=""
REPO="${REPO:-j-hc/revanced-magisk-module}"

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="${2:-}"; shift 2 ;;
        --out) OUT="${2:-}"; shift 2 ;;
        --repo) REPO="${2:-}"; shift 2 ;;
        --help|-h) sed -n '2,/^$/p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1 (try --help)"; exit 1 ;;
    esac
done

case "$APP" in
    youtube) MATCH="youtube-morphe-module-" ;;
    music) MATCH="music-morphe-module-" ;;
    reddit) MATCH="reddit-morphe-module-" ;;
    *) echo "[fetch] --app must be youtube|music|reddit"; exit 1 ;;
esac
[ -n "$OUT" ] || { echo "[fetch] --out is required"; exit 1; }
mkdir -p "$OUT"

echo "[fetch] scanning $REPO for $APP ($MATCH) ..."
URL=""
for t in $(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=10" \
        | grep '"tag_name"' | cut -d'"' -f4); do
    if [ "$APP" = "music" ]; then
        URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/$t" \
            | grep 'browser_download_url' | grep "$MATCH" | grep 'arm64' | grep '\.zip"' \
            | head -n1 | cut -d'"' -f4 || true)"
        [ -n "$URL" ] || URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/$t" \
            | grep 'browser_download_url' | grep "$MATCH" | grep '\.zip"' \
            | head -n1 | cut -d'"' -f4 || true)"
    else
        URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/$t" \
            | grep 'browser_download_url' | grep "$MATCH" | grep '\.zip"' \
            | head -n1 | cut -d'"' -f4 || true)"
    fi
    if [ -n "$URL" ]; then
        echo "[fetch] tag $t: $URL"
        break
    fi
done

[ -n "$URL" ] || { echo "[fetch] no $APP module in recent $REPO releases"; exit 1; }
curl -fL -o "$OUT/$APP-module.zip" "$URL"
echo "[fetch] saved $OUT/$APP-module.zip"
# Base version parsed from the asset name for callers stamping manifests.
BASE_VERSION="$(basename "$URL" | grep -m1 -o 'v[0-9][0-9.]*' | head -n1 || true)"
BASE_VERSION="${BASE_VERSION#v}"
echo "BASE_VERSION=$BASE_VERSION"
