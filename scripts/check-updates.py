#!/usr/bin/env python3
# Copyright (C) 2026 Samaksh Kamboj
# SPDX-License-Identifier: Apache-2.0
# check-updates.py — decide whether a build is needed by comparing the pins
# in config.toml against live upstreams, instead of rebuilding blindly on a
# timer. Sources of change:
#   * patch source tags (e.g. MorpheApp/morphe-patches releases) vs pinned rev
#   * stock base versions (parsed from the newest upstream-builder release
#     carrying each app's module) vs pinned base
# Only morphe streams are considered today; revanced/anddea pins are empty
# and skipped until those streams exist. Writes `build=true|false` (+reasons)
# to $GITHUB_OUTPUT in CI, prints JSON locally. Never fails the workflow:
# API errors resolve to build=true (stale releases are worse than a wasted
# run). FORCE_BUILD=1 forces true.
import json
import os
import re
import sys
import tomllib
import urllib.request

API = "https://api.github.com"
UPSTREAM_BUILDER = "j-hc/revanced-magisk-module"
MODULE_MATCH = {
    "youtube": "youtube-morphe-module-",
    "music": "music-morphe-module-",
    "reddit": "reddit-morphe-module-",
}


def api(path):
    req = urllib.request.Request(
        API + path,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "morphe-builder-check",
        },
    )
    token = os.environ.get("GITHUB_TOKEN", "")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def ver_tuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", v or ""))


def asset_version(name):
    m = re.search(r"v(\d[\d.]*)", name)
    return m.group(1).rstrip(".") if m else ""


def main():
    cfg = tomllib.load(open("config.toml", "rb"))
    reasons = []

    if os.environ.get("FORCE_BUILD") == "1":
        reasons.append("forced via FORCE_BUILD=1")

    # 1. Patch source revs.
    for variant, src in (cfg.get("sources") or {}).items():
        pin = (src.get("patches_rev") or "").strip()
        repo = (src.get("patches") or "").strip()
        if not pin or not repo or "/" not in repo:
            continue
        try:
            latest = api(f"/repos/{repo}/releases/latest").get("tag_name", "")
        except Exception as e:  # noqa: BLE001 - network flakes fail open
            reasons.append(f"{variant} patch check failed ({e}); building to be safe")
            continue
        if latest and latest != pin:
            reasons.append(f"{variant} patches {pin} -> {latest}")

    # 2. Stock base versions, newest-first per app.
    try:
        releases = api(f"/repos/{UPSTREAM_BUILDER}/releases?per_page=10")
    except Exception as e:  # noqa: BLE001
        releases = []
        reasons.append(f"base check failed ({e}); building to be safe")
    found: dict[str, str] = {}
    for rel in releases:
        tag = rel.get("tag_name", "")
        if not tag:
            continue
        try:
            full = api(f"/repos/{UPSTREAM_BUILDER}/releases/tags/{tag}")
        except Exception:  # noqa: BLE001 - try the next tag
            continue
        for a in full.get("assets", []):
            name = a.get("browser_download_url", "").rsplit("/", 1)[-1]
            if not name.endswith(".zip"):
                continue
            for app, match in MODULE_MATCH.items():
                if app in found or match not in name:
                    continue
                # Prefer arm64 music builds.
                if app == "music" and "arm64" not in name and any(
                    "arm64" in x for x in [y.get("browser_download_url", "") for y in full.get("assets", [])]
                    if match in x
                ):
                    continue
                v = asset_version(name)
                if v:
                    found[app] = v
        if all(a in found for a in (cfg.get("apps") or {})):
            break
    for app, want in (cfg.get("apps") or {}).items():
        pin = (want.get("base") or "").strip()
        live = found.get(app, "")
        if live and pin and ver_tuple(live) != ver_tuple(pin):
            reasons.append(f"{app} base {pin} -> {live}")

    build = bool(reasons)
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write(f"build={'true' if build else 'false'}\n")
    print(json.dumps({"build": build, "reasons": reasons}, indent=2))


if __name__ == "__main__":
    main()
