#!/usr/bin/env python3
"""Rank the executables of an extracted app tree to find the one the wrapper should exec.

Usage: find-executable.py <dir> [--name NAME]

Scores ELF executables (and scripts) by depth, name, size and location, and
penalizes helpers such as chrome-sandbox, crash handlers and updaters.
"""

import argparse
import os
import re
from pathlib import Path

HELPERS = ("chrome-sandbox", "chrome_sandbox", "crashpad", "crash_handler", "crash-reporter", "updater",
           "update", "helper", "sandbox", "daemon", "uninstall", "setup", "installer", "elevate", "launcher-helper")
GENERIC = {"run", "start", "launch", "main", "app"}
CI_PATHS = re.compile(rb"/home/runner/|/github/workspace|/build/|/workspace/|/builds/")


def variants(name):
    base = name.lower()
    base = re.sub(r"[-_.]v?\d+(\.\d+)+.*$", "", base)
    base = re.sub(r"[-_.](linux|x86[-_]64|amd64|x64|appimage|portable|gnu|musl)\b.*$", "", base)
    return {base, base.replace("-", ""), base.replace("_", ""), base.replace("-", "_"), base.replace("_", "-")} - {""}


def kind(path):
    try:
        with open(path, "rb") as f:
            head = f.read(4)
    except OSError:
        return None
    if head == b"\x7fELF":
        return "elf"
    if head[:2] == b"#!":
        return "script"
    return None


def score(path, root, names):
    rel = path.relative_to(root)
    stem = path.name.lower()
    size = path.stat().st_size
    depth = len(rel.parts) - 1
    points, reasons = 0, []

    def add(value, why):
        nonlocal points
        points += value
        reasons.append(f"{why} {value:+d}")

    add((11 - depth) * 10 if depth <= 10 else -50, f"depth {depth}")
    if stem in names:
        add(120, "name match")
    elif any(n in stem for n in names):
        add(60, "partial name")
    elif stem in GENERIC:
        add(30, "generic name")
    if stem not in names and any(h in stem for h in HELPERS):
        add(-200, "helper")
    if stem.startswith("lib"):
        add(-80, "lib prefix")
    if size > 10 << 20:
        add(30, ">10 MB")
    elif size > 1 << 20:
        add(10, ">1 MB")
    elif size < 1 << 10:
        add(-70, "<1 KB")
    elif size < 100 << 10:
        add(-20, "<100 KB")
    if "bin" in rel.parts[:-1]:
        add(20, "in bin/")
    if kind(path) == "script":
        add(-20, "script")
        if size < 10 << 10 and CI_PATHS.search(path.read_bytes()):
            add(-300, "CI build path inside")
    return points, reasons


def main():
    parser = argparse.ArgumentParser(description="Rank executables in an extracted app tree.")
    parser.add_argument("dir")
    parser.add_argument("--name", help="app name (default: directory name)")
    args = parser.parse_args()
    root = Path(args.dir).resolve()
    names = variants(args.name or root.name)

    ranked = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in {"node_modules", ".git", "locales", "__pycache__"}]
        for filename in filenames:
            path = Path(dirpath, filename)
            if path.is_symlink() or not os.access(path, os.X_OK) or re.search(r"\.(so(\.\d+)*|dylib|dll)$", filename):
                continue
            if kind(path):
                ranked.append((*score(path, root, names), path.relative_to(root)))
    ranked.sort(key=lambda item: (-item[0], str(item[2])))

    print(f"name variants: {', '.join(sorted(names))}")
    for points, reasons, rel in ranked[:10]:
        print(f"{points:5d}  {rel}\n       {', '.join(reasons)}")
    if not ranked:
        print("no executables found")


if __name__ == "__main__":
    main()
