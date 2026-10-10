#!/usr/bin/env bash
# Summarize a GitHub repository for packaging: metadata, releases, Linux x86_64
# assets, build files, desktop assets, and existing Arch/AUR packages.
#
# Usage: inspect-repo.sh <owner/repo | https://github.com/owner/repo>
set -euo pipefail

arg=${1:?usage: inspect-repo.sh <owner/repo | github url>}
repo=${arg#*github.com/}
repo=${repo%.git}
repo=$(cut -d/ -f1,2 <<<"$repo")
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "not a GitHub repository: $arg" >&2; exit 2; }

section() { printf '\n## %s\n' "$1"; }

section Repository
gh api "repos/$repo" --jq '
  "repo: \(.full_name)",
  "description: \(.description // "")",
  "homepage: \(.homepage // "")",
  "license: \(.license.spdx_id // "none")",
  "default_branch: \(.default_branch)",
  "archived: \(.archived)",
  "pushed_at: \(.pushed_at)",
  "topics: \(.topics | join(", "))"'
branch=$(gh api "repos/$repo" --jq .default_branch)
name=$(gh api "repos/$repo" --jq '.name | ascii_downcase | gsub("[^a-z0-9@._+-]"; "-")')
echo "package name: $name (dsr-$name, dsr-$name-bin)"
gh api "repos/$repo/languages" --jq 'to_entries | sort_by(-.value) | map(.key) | "languages: " + join(", ")'

section "Release assets"
"$(dirname "$0")/pick-asset.py" "$repo" || true

section "Recent tags"
gh api "repos/$repo/tags?per_page=5" --jq '.[].name' || true

section "Build files"
tree=$(gh api "repos/$repo/git/trees/$branch?recursive=1" --jq '.tree[] | select(.type == "blob") | .path' 2>/dev/null || true)
# Up to $1 tree paths matching the remaining grep arguments. No match is a normal result,
# and awk reads all input so pipefail never sees a SIGPIPE.
tree_match() {
  local limit=$1
  shift
  { grep "$@" <<<"$tree" || true; } | awk -v n="$limit" 'NR <= n { print "  " $0 }'
}
tree_match 40 -E '^([^/]+/)?(Cargo\.toml|package\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb?|go\.mod|CMakeLists\.txt|meson\.build|pyproject\.toml|setup\.py|Makefile|build\.gradle(\.kts)?|pom\.xml|pubspec\.yaml|flake\.nix|tauri\.conf\.json|electron-builder\.(json|ya?ml|js|cjs)|forge\.config\.(js|ts|cjs)|PKGBUILD|[^/]*\.spec|snapcraft\.yaml|[^/]*\.flatpak\.ya?ml|io\.[^/]*\.ya?ml)$'
tree_match 10 -E '^\.github/workflows/'

section "Desktop assets"
tree_match 10 -iE '\.desktop(\.in)?$|\.(metainfo|appdata)\.xml(\.in)?$'
tree_match 200 -iE '\.(svg|png)$' | { grep -iE 'icon|logo|hicolor|/(apps|assets|resources|build|static|public)/' || true; } |
  { grep -viE 'test|screenshot|docs?/|example|demo|node_modules' || true; } | awk 'NR <= 20'

if pkgjson=$(gh api "repos/$repo/contents/package.json" --jq .content 2>/dev/null | base64 -d 2>/dev/null); then
  section "package.json"
  jq -r '
    "name: \(.name // "")", "productName: \(.productName // .build.productName // "")",
    "desktopName: \(.desktopName // "")", "main: \(.main // "")",
    "electron: \(.devDependencies.electron // .dependencies.electron // "no")",
    "tauri: \(.devDependencies["@tauri-apps/cli"] // .dependencies["@tauri-apps/api"] // "no")",
    "packageManager: \(.packageManager // "")",
    "scripts: \(.scripts // {} | keys | join(", "))"' <<<"$pkgjson" 2>/dev/null || true
fi

section "Existing packages"
pacman -Si "$name" 2>/dev/null | grep -E '^(Repository|Name|Version)' | sed 's/^/  official: /' || true
curl -fsS "https://aur.archlinux.org/rpc/v5/search/$name?by=name" |
  jq -r '.results | sort_by(-.NumVotes) | .[:8][] | "  aur: \(.Name) \(.Version) votes=\(.NumVotes) maintainer=\(.Maintainer // "orphan")\(if .OutOfDate then " OUT-OF-DATE" else "" end)"' || true
find "$HOME/dev/dsr-aur/pkgs" -maxdepth 1 -name "dsr-$name*" -printf '  dsr-aur: %f\n' 2>/dev/null || true
