#!/usr/bin/env python3
# Copyright (C) 2026 Samaksh Kamboj
# SPDX-License-Identifier: Apache-2.0
# fetch-stock.py — obtain a pristine, MONOLITHIC stock base APK.
#
# Strategy, in order (first valid wins):
#   1. APKMirror release page: enumerate variant pages, score monolithic
#      candidates first (nodpi universal strongly preferred, arm64 next,
#      bundle/split penalized), download each in order and STRUCTURALLY
#      validate (root AndroidManifest.xml + dex + minimum arm64 lib set).
#   2. Upstream-module seed fallback: some bases (e.g. recent Reddit) exist
#      on APKMirror only as split-bundle repacks, whose nested base.apk
#      carries zero native libs and is unusable. Then the stock base is
#      extracted from the upstream builder's module zip (its stock/
#      entry is the pristine monolithic base) and validated the same way.
#
# A split repack must NEVER pass: the patcher NPEs on manifest-less input
# at best, and a libless base guarantees a runtime UnsatisfiedLinkError.
# Usage:
#   ./fetch-stock.py --release <release-page-url> --out <file>
#     [--upstream owner/repo] [--match reddit-morphe-module-] [--min-libs N]
import argparse
import re
import sys
import urllib.request
import zipfile
from io import BytesIO

UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36"}


def fetch(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def valid_base(data, min_libs, label):
    """A usable stock base: monolithic APK with manifest, dex and libs."""
    if data[:2] != b"PK":
        print(f"[stock] {label}: not a zip, rejecting", flush=True)
        return False
    try:
        z = zipfile.ZipFile(BytesIO(data))
        names = z.namelist()
    except Exception as e:  # noqa: BLE001
        print(f"[stock] {label}: unreadable zip ({e}), rejecting", flush=True)
        return False
    if "AndroidManifest.xml" not in names:
        print(f"[stock] {label}: no root manifest (split repack?), rejecting", flush=True)
        return False
    if not sum(1 for n in names if n.endswith(".dex")):
        print(f"[stock] {label}: no dex, rejecting", flush=True)
        return False
    libs = [n for n in names if n.startswith("lib/arm64-v8a/") and n.endswith(".so")]
    if len(libs) < min_libs:
        print(f"[stock] {label}: only {len(libs)} arm64 libs (min {min_libs}), rejecting", flush=True)
        return False
    print(f"[stock] {label}: valid ({len(libs)} arm64 libs)", flush=True)
    return True


def apkmirror_candidates(release):
    base = release.rstrip("/")
    rel = fetch(base).decode("utf-8", "ignore")
    variants = sorted(set(re.findall(r'href="([^"]*-android-apk-download/)"', rel)))
    variants = [v if v.startswith("http") else "https://www.apkmirror.com" + v for v in variants]
    variants = [v for v in variants if re.search(r"-\d+-android-apk-download/$", v)]

    def title(v):
        try:
            m = re.search(r"<title>(.*?)</title>",
                          fetch(v).decode("utf-8", "ignore"), re.S)
            return (m.group(1).strip().lower() if m else "")
        except Exception:  # noqa: BLE001
            return ""

    scored = []
    for v in variants:
        t = title(v)
        if not t:
            continue
        score = 0
        if "nodpi" in t:
            score += 10
        if "arm64-v8a" in t:
            score += 5
        if "bundle" in t or "split" in t or ".apkm" in t:
            score -= 100
        scored.append((score, t, v))
    scored.sort(reverse=True)
    return [(t, v) for _, t, v in scored]


def apkmirror_download(vpage):
    vhtml = fetch(vpage).decode("utf-8", "ignore")
    m = re.search(r"download/\?key=[^\"'&]+", vhtml)
    if not m:
        return None
    khtml = fetch(vpage.rstrip("/") + "/" + m.group(0)).decode("utf-8", "ignore")
    m = re.search(r"(/wp-content/themes/APKMirror/download\.php\?id=\d+&key=[a-f0-9]+)", khtml)
    if not m:
        return None
    return fetch("https://www.apkmirror.com" + m.group(1))


def seed_from_module(upstream, match, min_libs):
    """Newest upstream release holding <match>: extract its stock/*.apk."""
    api = "https://api.github.com/repos/"
    def get(url):
        req = urllib.request.Request(url, headers={**UA, "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            import json
            return json.load(r)
    rels = get(api + upstream + "/releases?per_page=10")
    for rel in rels:
        tag = rel.get("tag_name", "")
        if not tag:
            continue
        try:
            full = get(api + upstream + "/releases/tags/" + tag)
        except Exception:  # noqa: BLE001
            continue
        urls = [a.get("browser_download_url", "") for a in full.get("assets", [])
                if match in a.get("browser_download_url", "") and a.get("browser_download_url", "").endswith(".zip")]
        if "music" in match:
            urls = [u for u in urls if "arm64" in u] or urls
        if not urls:
            continue
        print(f"[stock] seed module tag {tag}: {urls[0].rsplit('/', 1)[-1]}", flush=True)
        mod = fetch(urls[0])
        z = zipfile.ZipFile(BytesIO(mod))
        stocks = [(i.filename, i.file_size) for i in z.infolist()
                  if i.filename.endswith(".apk") and "stock" in i.filename.lower()]
        if not stocks:
            continue
        data = z.read(max(stocks, key=lambda x: x[1])[0])
        if valid_base(data, min_libs, "seed stock base"):
            return data
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--release", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--upstream", default="j-hc/revanced-magisk-module")
    ap.add_argument("--match", default="")
    ap.add_argument("--min-libs", type=int, default=5)
    args = ap.parse_args()

    print(f"[stock] release page: {args.release.rstrip('/')}", flush=True)
    for title, vpage in apkmirror_candidates(args.release):
        print(f"[stock] trying: {title[:100]}", flush=True)
        try:
            data = apkmirror_download(vpage)
        except Exception as e:  # noqa: BLE001
            print(f"[stock] download failed ({e}), next", flush=True)
            continue
        if data is None:
            print("[stock] no direct link (bot check?), next", flush=True)
            continue
        if valid_base(data, args.min_libs, "candidate"):
            break
    else:
        data = None
    if data is None and args.match:
        print("[stock] no valid APKMirror candidate; trying upstream-module seed", flush=True)
        data = seed_from_module(args.upstream, args.match, args.min_libs)
    if data is None:
        sys.exit("[stock] FAILED: no usable stock base (see log). "
                 "Do not patch split repacks — nested base.apk files carry zero native libs.")
    with open(args.out, "wb") as f:
        f.write(data)
    print(f"[stock] saved {args.out} ({len(data) // 1048576} MB)", flush=True)


if __name__ == "__main__":
    main()
