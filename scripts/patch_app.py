#!/usr/bin/env python3
"""Set the Home Screen name, main icon and alternate icons of an unzipped .app bundle.

Usage:
  patch_app.py APP_DIR --name "My Tube" [--icon icon.png] [--alt NAME=path.png ...] [--bundle-id id]

Icons are written as loose PNG files and referenced through CFBundleIconFiles, so the
original asset-catalog icon (CFBundleIconName) is removed when a custom main icon is given.
"""
import argparse
import plistlib
import re
import sys
from pathlib import Path

from PIL import Image

# (points, scale, idiom suffix)
IPHONE = [(60, 2, ""), (60, 3, "")]
IPAD = [(76, 2, "~ipad"), (83.5, 2, "~ipad")]


def fmt_points(p: float) -> str:
    return f"{p:g}"


def write_icon_set(src: Path, app: Path, base: str) -> tuple[list[str], list[str]]:
    """Write one icon in every size. Returns (iphone_files, ipad_files) base names."""
    img = Image.open(src).convert("RGBA")
    side = min(img.size)
    left, top = (img.width - side) // 2, (img.height - side) // 2
    img = img.crop((left, top, left + side, top + side))
    # Home Screen icons must be opaque; iOS turns transparency black.
    flat = Image.new("RGB", img.size, (255, 255, 255))
    flat.paste(img, mask=img.split()[3])

    iphone, ipad = [], []
    for points, scale, idiom in IPHONE + IPAD:
        name = f"{base}{fmt_points(points)}x{fmt_points(points)}"
        px = round(points * scale)
        flat.resize((px, px), Image.LANCZOS).save(app / f"{name}@{scale}x{idiom}.png", "PNG")
        target = ipad if idiom else iphone
        if name not in target:
            target.append(name)
    return iphone, iphone + ipad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("app", type=Path)
    ap.add_argument("--name", required=True)
    ap.add_argument("--icon", type=Path)
    ap.add_argument("--alt", action="append", default=[], help="NAME=path.png")
    ap.add_argument("--bundle-id")
    args = ap.parse_args()

    plist_path = args.app / "Info.plist"
    with open(plist_path, "rb") as f:
        info = plistlib.load(f)

    name = args.name.strip()[:30] or "YTHelper"
    info["CFBundleDisplayName"] = name
    info["CFBundleName"] = name[:15]
    if args.bundle_id:
        info["CFBundleIdentifier"] = args.bundle_id

    icons = info.setdefault("CFBundleIcons", {})
    icons_ipad = info.setdefault("CFBundleIcons~ipad", {})

    if args.icon:
        iphone, ipad = write_icon_set(args.icon, args.app, "YTHelperIcon")
        for d, files in ((icons, iphone), (icons_ipad, ipad)):
            primary = d.setdefault("CFBundlePrimaryIcon", {})
            primary.pop("CFBundleIconName", None)
            primary["CFBundleIconFiles"] = files
        info.pop("CFBundleIconName", None)
        info.pop("CFBundleIconFiles", None)

    alts, alts_ipad = {}, {}
    for spec in args.alt:
        if "=" not in spec:
            print(f"ignoring alt icon without NAME=: {spec}", file=sys.stderr)
            continue
        alt_name, path = spec.split("=", 1)
        alt_name = alt_name.strip()
        safe = re.sub(r"[^A-Za-z0-9]", "", alt_name) or f"Icon{len(alts) + 1}"
        iphone, ipad = write_icon_set(Path(path), args.app, f"YTHAlt{safe}")
        alts[alt_name] = {"CFBundleIconFiles": iphone}
        alts_ipad[alt_name] = {"CFBundleIconFiles": ipad}
    if alts:
        icons["CFBundleAlternateIcons"] = alts
        icons_ipad["CFBundleAlternateIcons"] = alts_ipad

    with open(plist_path, "wb") as f:
        plistlib.dump(info, f, fmt=plistlib.FMT_BINARY)
    print(f"Patched {plist_path}: name={name!r}, icon={'custom' if args.icon else 'original'}, alt icons={list(alts)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
