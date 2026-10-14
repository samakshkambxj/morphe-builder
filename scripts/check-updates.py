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
# Our own releases: the build gate compares config pins against the last
# published manifest (hermetic stable), not against live drift.
SELF_REPO = os.environ.get("UPDATES_SELF_REPO", "samakshkambxj/morphe-builder")
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


def compare_pins(cfg, manifest):
    """Diff config pins against a published manifest. Returns reason list."""
    reasons = []
    man_apps = (manifest or {}).get("apps", {})
    man_rev = (manifest or {}).get("patch_rev", "")
    cfg_rev = (((cfg.get("sources") or {}).get("morphe") or {}).get("patches_rev") or "").strip()
    if cfg_rev and man_rev and cfg_rev != man_rev:
        reasons.append(f"patches {man_rev} -> {cfg_rev}")
    elif cfg_rev and not man_rev:
        reasons.append(f"patches {cfg_rev} not yet released")
    for app, want in (cfg.get("apps") or {}).items():
        pin = (want.get("base") or "").strip()
        built = ((man_apps.get(app) or {}).get("base_version") or "").strip()
        if pin and built and ver_tuple(pin) != ver_tuple(built):
            reasons.append(f"{app} pin {built} -> {pin}")
        elif pin and not built:
            reasons.append(f"{app} {pin} not yet released")
    return reasons


def fetch_manifest():
    """Our latest release's versions.json, or None when never released."""
    try:
        rel = api(f"/repos/{SELF_REPO}/releases/latest")
    except Exception:  # noqa: BLE001 - 404 on first ever run
        return None
    for a in rel.get("assets", []):
        if a.get("name", "") == "versions.json":
            req = urllib.request.Request(
                a["browser_download_url"],
                headers={"User-Agent": "morphe-builder-check"},
            )
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
    return None


def asset_version(name):
    m = re.search(r"v(\d[\d.]*)", name)
    return m.group(1).rstrip(".") if m else ""


def main():
    cfg = tomllib.load(open("config.toml", "rb"))

    # 1. What changed upstream (informational: drives promotion PRs, and a
    # build only when pins were already bumped to match it).
    updates: list[str] = []
    for variant, src in (cfg.get("sources") or {}).items():
        pin = (src.get("patches_rev") or "").strip()
        repo = (src.get("patches") or "").strip()
        if not pin or not repo or "/" not in repo:
            continue
        try:
            latest = api(f"/repos/{repo}/releases/latest").get("tag_name", "")
        except Exception as e:  # noqa: BLE001 - network flakes fail open
            updates.append(f"{variant} patch check failed ({e})")
            continue
        if latest and latest != pin:
            updates.append(f"{variant} patches {pin} -> {latest}")

    # 2. Stock base versions, newest-first per app.
    try:
        releases = api(f"/repos/{UPSTREAM_BUILDER}/releases?per_page=10")
    except Exception as e:  # noqa: BLE001
        releases = []
        updates.append(f"base check failed ({e})")
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
            updates.append(f"{app} base {pin} -> {live}")

    # 3. Build gate: config pins vs OUR last published manifest. Hermetic
    # stable — live drift alone never rebuilds identical pins.
    build_reasons: list[str] = list(updates)
    try:
        manifest = fetch_manifest()
    except Exception as e:  # noqa: BLE001
        manifest = None
        build_reasons.append(f"own-release check failed ({e})")
    if manifest is None:
        build_reasons.append("no prior release; building")
        build = True
    else:
        pin_diff = compare_pins(cfg, manifest)
        build_reasons.extend(f"pin advanced, {r}" if "not yet released" not in r else r for r in pin_diff)
        build = bool(pin_diff)
    if os.environ.get("FORCE_BUILD") == "1" and not build:
        build = True
        build_reasons.append("forced via FORCE_BUILD=1")

    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write(f"build={'true' if build else 'false'}\n")
            f.write(f"updates={'true' if updates else 'false'}\n")
    print(json.dumps(
        {"build": build, "build_reasons": build_reasons,
         "updates_available": bool(updates), "updates": updates}, indent=2))


if __name__ == "__main__":
    main()
