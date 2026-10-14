#!/usr/bin/env python3
# Copyright (C) 2026 Samaksh Kamboj
# SPDX-License-Identifier: Apache-2.0
# fetch-stock.py — download a pristine stock base APK from APKMirror.
# Given a release page, lists variant pages, scores them (arm64-v8a first,
# nodpi preferred, never bundles), then follows variant page -> key link ->
# download.php to the binary. Verifies zip magic + plausible size.
# Usage:
#   ./fetch-stock.py --release <release-page-url> --out <file>
#                    [--prefer <arch, default arm64-v8a>] [--nodpi]
import argparse
import re
import sys
import urllib.request

UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36"}


def fetch(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def title_of(html):
    m = re.search(r"<title>(.*?)</title>", html.decode("utf-8", "ignore"), re.S)
    return (m.group(1).strip() if m else "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--release", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--prefer", default="arm64-v8a")
    ap.add_argument("--nodpi", action="store_true")
    args = ap.parse_args()

    base = args.release.rstrip("/")
    print(f"[stock] release page: {base}", flush=True)
    rel = fetch(base).decode("utf-8", "ignore")
    variants = sorted(set(re.findall(r'href="([^"]*-android-apk-download/)"', rel)))
    variants = [v if v.startswith("http") else "https://www.apkmirror.com" + v for v in variants]
    # Drop the bare release-level link (not a concrete variant).
    variants = [v for v in variants if re.search(r"-\d+-android-apk-download/$", v)]
    if not variants:
        sys.exit("[stock] no variant pages found")
    print(f"[stock] {len(variants)} variants", flush=True)

    scored = []
    for v in variants:
        try:
            t = title_of(fetch(v)).lower()
        except Exception as e:  # noqa: BLE001 - one bad variant page skips
            print(f"[stock] variant fetch failed, skipping: {v} ({e})", flush=True)
            continue
        score = 0
        if args.prefer in t:
            score += 10
        if "nodpi" in t:
            score += 5
        if "bundle" in t or ".apkm" in t:
            score -= 100
        scored.append((score, t, v))
    if not scored:
        sys.exit("[stock] no usable variant")
    scored.sort(reverse=True)
    print(f"[stock] picked: {scored[0][1][:100]}", flush=True)
    vpage = scored[0][2]

    vhtml = fetch(vpage).decode("utf-8", "ignore")
    m = re.search(r"download/\?key=[^\"'&]+", vhtml)
    if not m:
        sys.exit("[stock] no key link on variant page")
    key_url = vpage.rstrip("/") + "/" + m.group(0)
    khtml = fetch(key_url).decode("utf-8", "ignore")
    m = re.search(r"(/wp-content/themes/APKMirror/download\.php\?id=\d+&key=[a-f0-9]+)", khtml)
    if not m:
        sys.exit("[stock] no direct download link (bot check?)")
    data = fetch("https://www.apkmirror.com" + m.group(1))
    if data[:2] != b"PK":
        sys.exit("[stock] download is not a zip (bot check page?)")
    if len(data) < 10 * 1024 * 1024:
        sys.exit(f"[stock] suspiciously small ({len(data)} bytes)")
    with open(args.out, "wb") as f:
        f.write(data)
    print(f"[stock] saved {args.out} ({len(data) // 1048576} MB)", flush=True)


if __name__ == "__main__":
    main()
