#!/usr/bin/env bash
# Build package directories natively in the dsr-aur image, as the CI build workflow does:
# resolve upstream versions (.nvchecker.toml), then the builder bumps and builds (flags,
# per-package users, dependency passes). Packages are copied out.
# Packages that depend on each other can be passed together.
#
# Usage: test-build.sh <pkgdir>...
# Env:   DSR_AUR_DIR  repository checkout (default ~/dev/dsr-aur)
#        OUT_DIR      where packages land (default ./dsr-test-out); emptied first
set -euo pipefail

(( $# )) || { echo "usage: test-build.sh <pkgdir>..." >&2; exit 2; }
repo_dir=${DSR_AUR_DIR:-$HOME/dev/dsr-aur}
out_dir=$(realpath -m "${OUT_DIR:-dsr-test-out}")
image=dsr-aur-builder:local
run=dsr-test-$$
src=$(mktemp -d)

# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
  docker rm -f "$run" >/dev/null 2>&1 || true
  docker volume rm -f "$run-repo" "$run-exchange" "$run-control" >/dev/null 2>&1 || true
  rm -rf "$src"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$src/pkgs" "$out_dir"
rm -f "$out_dir"/*.pkg.tar.*
: >"$src/aur.txt"
for dir; do
  dir=$(realpath "$dir")
  [[ -f $dir/PKGBUILD ]] || { echo "no PKGBUILD in $dir" >&2; exit 2; }
  cp -r "$dir" "$src/pkgs/"
done

echo "==> Building image $image"
docker build -q -f "$repo_dir/builder/Dockerfile" -t "$image" "$repo_dir" >/dev/null

echo "==> Resolving upstream versions"
if ! docker run --rm -e GITHUB_TOKEN -v "$run-control:/srv/control" -v "$src:/src:ro" "$image" dsr-publish versions; then
  echo "==> Upstream version resolution failed (see above); fix .nvchecker.toml or set GITHUB_TOKEN" >&2
  exit 1
fi

start=$SECONDS
status=0
docker run --name "$run" --init -v "$run-repo:/srv/repo:ro" -v "$run-exchange:/srv/exchange" \
  -v "$run-control:/srv/control:ro" -v "$src:/src:ro" "$image" dsr-build once || status=$?
docker rm "$run" >/dev/null
echo "==> Build took $((SECONDS - start))s natively; expect about 5x in CI (4 vCPUs, 340-minute job limit)"

docker run --rm -v "$run-exchange:/x:ro" -v "$out_dir:/out" alpine sh -c \
  "set -e; for f in /x/incoming/*/packages/*.pkg.tar.*; do [ -e \"\$f\" ] && cp \"\$f\" /out/; done; chown -R $(id -u):$(id -g) /out"
shopt -s nullglob
packages=("$out_dir"/*.pkg.tar.*)
printf '%s\n' "${packages[@]}"
if (( status == 0 && ${#packages[@]} == 0 )); then
  echo "==> The build reported success but produced no packages" >&2
  exit 1
fi
exit "$status"
