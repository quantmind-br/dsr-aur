#!/usr/bin/env python3
"""Rank app icon candidates in an extracted tree or an Electron app.asar.

Usage: find-icons.py <dir | app.asar> --name NAME [--extract DIR]

Keeps square PNG/SVG/XPM files, drops toolbar, tray and theme-variant icons,
maps each to a hicolor size (rounded up to a standard size, capped at 512),
and prints install lines. --extract copies the best icons out of an asar (or a
tree) into DIR, for committing beside the PKGBUILD, and prints install lines
for those copies.
"""

import argparse
import json
import os
import re
import struct
from pathlib import Path

SIZES = (16, 22, 24, 32, 48, 64, 128, 256, 512)
SKIP_DIRS = {"node_modules", ".git", "__pycache__", "locales", "vendor", "test", "tests", "docs", "screenshots"}
NOT_APP_ICON = re.compile(
    r"(-tb\.|[-_](dark|light|white|black|mono|monochrome|symbolic|template|inverted|tray|badge|small)[-_.@]"
    r"|(^|/)(status|folder|file|debug|tray|notification|badge|overlay|menu|toolbar|button|arrow|close"
    r"|minimize|maximize|flag|emoji)[-_]|/(emoji|flags|toolbar|tray)/)")


def png_size(data):
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        return struct.unpack(">II", data[16:24])
    return None


def svg_size(data):
    text = data[:4096].decode("utf-8", "ignore")
    box = re.search(r'viewBox="[\d.\s-]*?([\d.]+)[\s,]+([\d.]+)"', text)
    if box:
        return float(box.group(1)), float(box.group(2))
    w, h = re.search(r'width="([\d.]+)', text), re.search(r'height="([\d.]+)', text)
    return (float(w.group(1)), float(h.group(1))) if w and h else (1.0, 1.0)


def walk_tree(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for filename in filenames:
            path = Path(dirpath, filename)
            if not path.is_symlink() and path.suffix.lower() in {".png", ".svg", ".xpm"}:
                yield str(path.relative_to(root)), path.read_bytes
                # read lazily: only candidates that pass the name filter are read


def walk_asar(path):
    with open(path, "rb") as f:
        header_size = struct.unpack("<I", f.read(8)[4:8])[0]
        json_len = struct.unpack("<I", f.read(8)[4:8])[0]
        header = json.loads(f.read(json_len))
    base = 8 + header_size

    def reader(offset, size):
        def read():
            with open(path, "rb") as f:
                f.seek(base + offset)
                return f.read(size)
        return read

    def visit(node, prefix):
        for name, entry in node.get("files", {}).items():
            rel = f"{prefix}{name}"
            if "files" in entry:
                if name not in SKIP_DIRS:
                    yield from visit(entry, rel + "/")
            elif not entry.get("unpacked") and "offset" in entry and Path(name).suffix.lower() in {".png", ".svg"}:
                yield rel, reader(int(entry["offset"]), entry["size"])

    yield from visit(header, "")


def main():
    parser = argparse.ArgumentParser(description="Rank app icon candidates.")
    parser.add_argument("source")
    parser.add_argument("--name", required=True, help="icon name to install (the package's <name>)")
    parser.add_argument("--extract", help="copy candidates into this directory")
    args = parser.parse_args()
    source = Path(args.source)
    entries = walk_asar(source) if source.suffix == ".asar" else walk_tree(source)
    app = re.sub(r"[^a-z0-9]", "", args.name.lower())

    candidates = []
    for rel, read in entries:
        lower = rel.lower()
        if NOT_APP_ICON.search(lower) or lower.endswith(".ico"):
            continue
        data = read()
        if len(data) < 100:
            continue
        ext = Path(rel).suffix.lower()
        if ext == ".svg":
            w, h = svg_size(data)
        elif ext == ".png":
            dims = png_size(data)
            if not dims:
                continue
            w, h = dims
        else:
            match = re.search(r"(\d+)x(\d+)", rel)
            w, h = (int(match.group(1)), int(match.group(2))) if match else (0, 0)
        # hicolor icons are square; an SVG viewBox may be off by a few units.
        if not w or not h or (ext == ".svg" and max(w, h) / min(w, h) > 1.05) or (ext != ".svg" and w != h):
            continue
        points = 0
        parts = Path(lower).parts
        stem = re.sub(r"[^a-z0-9]", "", re.sub(r"[-_.@]?\d+x\d+|@\dx", "", Path(lower).stem))
        if app and stem == app:
            points += 120
        elif re.match(r"(appicon|icon|logo)", stem):
            points += 60
        elif app and app in stem:
            points += 40
        if any(p in {"icons", "icon", "logo", "logos", "hicolor", "apps", "pixmaps"} for p in parts[:-1]):
            points += 40
        if re.search(r"\.[0-9a-f]{8,}\.", Path(lower).name) or "web-static" in lower:
            points -= 60
        if re.search(r"(beta|canary|nightly|internal|dev|insiders|preview)", stem):
            points -= 40
        if ext == ".svg":
            points += 40
            target = "scalable"
        else:
            points += min(int(w), 512) // 16
            target = next((s for s in SIZES if s >= w), 512)
        candidates.append((points, rel, int(w), int(h), ext, target, data))

    candidates.sort(key=lambda c: (-c[0], c[5] != "scalable" and c[2] != c[5], c[1]))  # exact sizes first
    if not candidates:
        print("no icon candidates")
        return
    best = {}
    for c in candidates:  # best file per hicolor size, ignoring weak matches
        if c[0] >= 60:
            best.setdefault(c[5], c)
    if not best:
        print("no strong candidate: pick one from the list by hand")
    for points, rel, w, h, ext, target, _ in candidates[:15]:
        mark = "*" if target in best and best[target][1] == rel else " "
        print(f"{mark}{points:4d}  {rel}  ({w}x{h}{ext}) -> {target}")

    print("\ninstall (best per size):")
    out = Path(args.extract) if args.extract else None
    if out:
        out.mkdir(parents=True, exist_ok=True)
    extracted = []
    for target, (_, rel, w, _, ext, _, data) in sorted(best.items(), key=lambda kv: str(kv[0])):
        if target == "scalable":
            dest = f"/usr/share/icons/hicolor/scalable/apps/{args.name}.svg"
        else:
            dest = f"/usr/share/icons/hicolor/{target}x{target}/apps/{args.name}{ext}"
        resize = "" if target == "scalable" or w == target else f"   # resize {w} -> {target} first"
        source = rel
        if out:
            source = f"{args.name}.svg" if target == "scalable" else f"{args.name}-{target}{ext}"
            (out / source).write_bytes(data)
            extracted.append(source)
        print(f'  install -Dm644 "{source}" "$pkgdir{dest}"{resize}')
    if out:
        print(f"\nextracted into {out} (it must be the PKGBUILD's directory); add: source+=({' '.join(extracted)})")

if __name__ == "__main__":
    main()
