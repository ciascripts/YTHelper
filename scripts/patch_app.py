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


NAME_KEYS = ("CFBundleDisplayName", "CFBundleName")


def _strings_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def patch_localized_names(app: Path, name: str) -> int:
    """Localized InfoPlist.strings override Info.plist, so set the name there too.

    Handles binary/XML plists and text .strings files (UTF-8 or UTF-16).
    Returns how many files were changed.
    """
    changed = 0
    for strings in sorted(app.glob("*.lproj/InfoPlist.strings")):
        raw = strings.read_bytes()
        if raw.startswith(b"bplist") or raw.lstrip().startswith(b"<?xml"):
            data = plistlib.loads(raw)
            if not any(k in data for k in NAME_KEYS):
                continue
            for k in NAME_KEYS:
                if k in data:
                    data[k] = name if k == "CFBundleDisplayName" else name[:15]
            fmt = plistlib.FMT_BINARY if raw.startswith(b"bplist") else plistlib.FMT_XML
            strings.write_bytes(plistlib.dumps(data, fmt=fmt))
            changed += 1
            continue
        encoding = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8"
        text = raw.decode(encoding)
        new_text = text
        for k in NAME_KEYS:
            value = _strings_escape(name if k == "CFBundleDisplayName" else name[:15])
            pattern = re.compile(r'("?' + k + r'"?\s*=\s*)"(?:[^"\\]|\\.)*"(\s*;)')
            new_text = pattern.sub(lambda m: f'{m.group(1)}"{value}"{m.group(2)}', new_text)
        if new_text != text:
            strings.write_bytes(new_text.encode(encoding))
            changed += 1
    return changed


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
    localized = patch_localized_names(args.app, name)
    print(f"Updated localized names in {localized} .lproj folder(s)")
    print(f"Patched {plist_path}: name={name!r}, icon={'custom' if args.icon else 'original'}, alt icons={list(alts)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
