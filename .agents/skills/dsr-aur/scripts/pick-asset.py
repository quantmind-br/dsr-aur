#!/usr/bin/env python3
"""Rank a GitHub release's assets for an x86_64 glibc Arch Linux package.

Usage: pick-asset.py <owner/repo | github url> [--tag TAG]

Prints the release, Linux x86_64 candidates ranked with score reasons, every
excluded asset with its reason, a source= line template and a suggested
.nvchecker.toml section. Needs an authenticated `gh`.
"""

import argparse
import json
import re
import subprocess
import sys

# A token counts only when not glued to other letters or digits.
B = r"(?<![a-z0-9])"
E = r"(?![a-z0-9])"

EXCLUDE = [
    (r"\.(sha(1|256|512)|md5)(sums?)?(\.txt)?$", "checksum"),
    (B + r"(checksums?|sha(256|512)?sums?)" + E, "checksum"),
    (r"\.(sig|asc|minisig|pem|crt|cert)$", "signature"),
    (B + r"(debug|dbg|symbols)" + E + r"|\.pdb$", "debug symbols"),
    (B + r"(sources?|src|source[-_]?code)\.(tar(\.\w+)?|tgz|zip)$|\.src\.(tar|rpm)", "source archive"),
    (r"\.(zsync|torrent|blockmap|json|ya?ml|txt|md|spdx|sbom|jsonl)$", "metadata"),
    (B + r"(sbom|provenance|attestation)" + E, "metadata"),
    (r"\.(snap|flatpak|flatpakref|flatpakrepo)$", "sandboxed bundle"),
    (r"\.(dmg|pkg)$|\.app(\.(tar|zip)|$)|" + B + r"(darwin|macos|mac|osx|apple)" + E, "macOS"),
    (r"\.(exe|msi|msix|appx|nupkg)$|" + B + r"(windows|win32|win64|win)" + E, "Windows"),
    (r"\.(apk|aab|ipa)$|" + B + r"(android|ios)" + E, "mobile"),
    (B + r"(freebsd|netbsd|openbsd|solaris|illumos|dragonfly)" + E, "other OS"),
]

ARCH_X86_64 = B + r"(x86[-_]64|amd64|x64|x86_64[-_]v[1-4])" + E
ARCH_OTHER = B + r"(aarch64|arm[-_]?64|armv[5-8]\w*|armhf|armel|arm|i[3-6]86|386|ia32|x86|(ppc|powerpc)\w*|s390x|riscv\w*|sparc\w*|loong\w*|mips\w*)" + E
ARCH_UNIVERSAL = B + r"(universal2?|noarch|any|all)" + E
LINUX = B + r"(linux|gnu|glibc|musl)" + E

FORMATS = [  # (regex, label, points): Arch-native first, then easiest to repackage.
    (r"\.pkg\.tar\.(zst|xz)$", "pacman package", 90),
    (r"\.(tar\.(gz|xz|zst|bz2)|tgz|txz)$", "tarball", 70),
    (r"\.deb$", "deb", 50),
    (r"\.appimage$", "AppImage", 40),
    (r"\.rpm$", "rpm", 20),
    (r"\.zip$", "zip", 15),
    (r"\.run$", "installer script", 0),
    (r"\.bin$", "bare binary", 10),
]
LINUX_ONLY_FORMATS = {"pacman package", "deb", "AppImage", "rpm"}


def gh(path):
    result = subprocess.run(["gh", "api", path], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)


def resolve_release(repo, tag):
    if tag:
        return gh(f"repos/{repo}/releases/tags/{tag}"), False
    latest = gh(f"repos/{repo}/releases/latest")
    if latest:
        return latest, False
    # /releases/latest hides prereleases and returns 404 when only those exist.
    releases = [r for r in gh(f"repos/{repo}/releases?per_page=30") or [] if not r["draft"]]
    return (releases[0], True) if releases else (None, False)


def name_variants(repo):
    name = repo.split("/")[1].lower()
    return {name, name.replace("-", ""), name.replace("_", ""), name.replace("-", "_")}


def classify(asset, variants):
    """Return (score, reasons) or (None, exclusion reason)."""
    name = asset["name"].lower()
    for pattern, reason in EXCLUDE:
        if re.search(pattern, name):
            return None, reason
    fmt = next(((label, pts) for pattern, label, pts in FORMATS if re.search(pattern, name)), None)
    if not fmt and not re.fullmatch(r"[a-z][a-z0-9]{0,4}", name.rsplit(".", 1)[-1] if "." in name else "-"):
        fmt = ("bare binary", 10)  # no extension, or dots only inside a version: "foo-v1.2.3-linux-x86_64"
    if not fmt:
        return None, "unsupported format"
    label, points = fmt
    if re.search(ARCH_OTHER, name) and not re.search(ARCH_X86_64, name):
        return None, "other architecture"

    score, reasons = points, [f"{label} +{points}"]
    if re.search(LINUX, name):
        score += 400
        reasons.append("linux +400")
    elif label in LINUX_ONLY_FORMATS:
        score += 400
        reasons.append("linux format +400")
    else:
        score += 200
        reasons.append("no OS token +200")
    if re.search(ARCH_X86_64, name):
        score += 300
        reasons.append("x86_64 +300")
    elif re.search(ARCH_UNIVERSAL, name):
        score += 100
        reasons.append("universal +100")
    if re.search(B + r"musl" + E, name):
        score -= 40
        reasons.append("musl -40")
    elif re.search(B + r"(gnu|glibc)" + E, name):
        score += 60
        reasons.append("glibc +60")
    if any(v in name for v in variants):
        score += 15
        reasons.append("app name +15")
    if re.search(B + r"(unsigned|alpha|nightly|beta|rc\d*|dev|canary)" + E, name):
        score -= 10
        reasons.append("unstable -10")
    if asset["size"] < 1 << 20:
        score -= 5
        reasons.append("<1 MiB -5")
    return score, reasons


def split_tag(tag: str) -> tuple[str, str]:
    """Split a tag into (prefix, version): "desktop-v1.2" -> ("desktop-v", "1.2")."""
    match = re.match(r"^(.*?)(\d.*)$", tag)
    return (match.group(1) or "", match.group(2) or "") if match else (tag, "")


def version_regex(prefix, version):
    """nvchecker include_regex (full match): stable numbers only, unless upstream never has them."""
    tail = r"\d+(\.\d+)*" if re.fullmatch(r"\d+(\.\d+)*", version) else r"\d.*"
    return f"include_regex = '{re.escape(prefix)}{tail}'"


def nvchecker_section(repo, release, prerelease_only, all_releases):
    tag: str = release["tag_name"] if release else ""
    lines = ["[<pkgname>]", 'source = "github"', f'github = "{repo}"']
    notes = []
    if not release:
        tags = gh(f"repos/{repo}/tags?per_page=30") or []
        if not tags:
            return lines + ["# no releases and no tags: use a -git package instead"], notes
        tag = tags[0]["name"]
        prefix, version = split_tag(tag)
        lines += ["use_max_tag = true", version_regex(prefix, version)]
        if prefix:
            lines.append(f'prefix = "{prefix}"')
    else:
        prefix, version = split_tag(tag)
        prefixes = {split_tag(r["tag_name"])[0] for r in all_releases}
        component = prefix.lower().rstrip("v-_") not in ("", "release", "version")
        if component and len(prefixes) > 1:
            # Monorepo: several components release from one repository.
            lines += ["use_max_release = true", version_regex(prefix, version)]
            notes.append(f"monorepo tags {sorted(prefixes)}: following only '{prefix}'")
        else:
            lines.append("use_latest_release = true")
        if prerelease_only:
            # use_latest_release with include_prereleases needs a GitHub token (GraphQL); this does not.
            lines = [line for line in lines if line != "use_latest_release = true"]
            if "use_max_release = true" not in lines:
                lines.append("use_max_release = true")
            lines.append("include_prereleases = true")
            notes.append("only prereleases exist")
        if prefix:
            lines.append(f'prefix = "{prefix}"')
    if "-" in version:
        lines += ["from_pattern = '-'", "to_pattern = '_'"]
        notes.append("version contains '-': use ${pkgver//_/-} wherever the upstream version appears")
    if re.search(r"[^A-Za-z0-9._+-]", version):
        notes.append(f"version '{version}' has characters pkgver cannot hold: add from_pattern/to_pattern")
    if re.match(r"^(19|20)\d{2}[-.]?\d{2}[-.]?\d{2}", version):
        notes.append("date-based version")
    return lines, notes


def main():
    parser = argparse.ArgumentParser(description="Rank GitHub release assets for an Arch Linux package.")
    parser.add_argument("repo")
    parser.add_argument("--tag")
    args = parser.parse_args()
    repo = re.sub(r"^.*github\.com/", "", args.repo).removesuffix(".git").strip("/")
    repo = "/".join(repo.split("/")[:2])
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
        sys.exit(f"not a GitHub repository: {args.repo}")

    release, prerelease_only = resolve_release(repo, args.tag)
    all_releases = [r for r in gh(f"repos/{repo}/releases?per_page=30") or [] if not r["draft"]]
    if release:
        flag = " (prerelease: no stable release exists)" if prerelease_only else ""
        print(f"release: {release['tag_name']}{flag}  published {release['published_at']}")
    else:
        print("release: none")

    variants = name_variants(repo)
    ranked, excluded = [], []
    for asset in (release or {}).get("assets", []):
        score, why = classify(asset, variants)
        (excluded if score is None else ranked).append((score, asset, why))
    ranked.sort(key=lambda item: (-item[0], item[1]["name"]))

    print("\ncandidates:")
    for score, asset, reasons in ranked:
        digest = asset.get("digest") or "no digest"
        print(f"  {score:4d}  {asset['name']}  ({asset['size'] >> 10} KiB, {digest})")
        print(f"        {', '.join(reasons)}")
    if not ranked:
        print("  none: no Linux x86_64 asset, skip the -bin package")
    evidence = bool(ranked) and any(r.startswith(("linux", "x86_64")) for r in ranked[0][2])
    if ranked and not evidence:
        chosen = ranked[0][1]
        print("\nchosen: none (the name shows neither Linux nor x86_64: inspect the file before using it)")
    elif ranked and (len(ranked) == 1 or ranked[0][0] - ranked[1][0] >= 20):
        chosen = ranked[0][1]
        print(f"\nchosen: {chosen['name']}")
    elif ranked:
        chosen = ranked[0][1]
        print("\nchosen: none (top candidates within 20 points: decide by content, e.g. GUI vs CLI)")
    else:
        chosen = None

    print("\nexcluded:")
    for _, asset, reason in sorted(excluded, key=lambda item: item[1]["name"]):
        print(f"  {asset['name']}: {reason}")

    if chosen and release:
        prefix, version = split_tag(release["tag_name"])
        upstream = "${pkgver//_/-}" if "-" in version else "$pkgver"
        asset_tpl = chosen["name"].replace(version, upstream) if version else chosen["name"]
        ext = next((m.group(0) for m in [re.search(r"(\.pkg)?\.tar\.\w+$|\.\w+$", chosen["name"])] if m), "")
        print("\nsource template:")
        print(f'  "$_name-$pkgver{ext}::$url/releases/download/{prefix}{upstream}/{asset_tpl}"')
        if version and version not in chosen["name"]:
            print("  (version-less asset name: the $_name-$pkgver rename keeps cached downloads apart)")

    lines, notes = nvchecker_section(repo, release, prerelease_only, all_releases)
    print("\n.nvchecker.toml:")
    for line in lines:
        print(f"  {line}")
    for note in notes:
        print(f"  # {note}")


if __name__ == "__main__":
    main()
