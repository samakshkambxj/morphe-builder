#!/usr/bin/env python3
# Copyright (C) 2026 Samaksh Kamboj
# SPDX-License-Identifier: Apache-2.0
# extract-stock.py — pull the pristine stock base out of a module zip
# (largest APK under stock/) for floating (beta) builds, where the stock
# base comes from the newest module itself instead of a pinned APKMirror
# page. Validates the same way fetch-stock.py does.
# Usage: ./extract-stock.py --module <zip> --out <apk> [--min-libs N]
import argparse
import sys
import zipfile
from io import BytesIO


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--module", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--min-libs", type=int, default=5)
    args = ap.parse_args()

    z = zipfile.ZipFile(args.module)
    stocks = [(i.filename, i.file_size) for i in z.infolist()
              if i.filename.endswith(".apk") and "stock" in i.filename.lower()]
    if not stocks:
        sys.exit(f"[extract] no stock APK in {args.module}")
    src = max(stocks, key=lambda x: x[1])[0]
    data = z.read(src)
    inner = zipfile.ZipFile(BytesIO(data))
    names = inner.namelist()
    assert "AndroidManifest.xml" in names, "no root manifest"
    assert any(n.endswith(".dex") for n in names), "no dex"
    libs = [n for n in names if n.startswith("lib/arm64-v8a/") and n.endswith(".so")]
    assert len(libs) >= args.min_libs, f"only {len(libs)} arm64 libs"
    with open(args.out, "wb") as f:
        f.write(data)
    print(f"[extract] {src} -> {args.out} ({len(data) // 1048576} MB, {len(libs)} arm64 libs)", flush=True)


if __name__ == "__main__":
    main()
