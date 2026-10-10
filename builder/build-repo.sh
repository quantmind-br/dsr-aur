#!/usr/bin/env bash
# Build outdated packages from $SOURCE_DIR into a signed pacman repository.
#
# Usage: build-repo [once|loop]
#   once  build every outdated package, update the database, then exit
#   loop  run "once" now and again every $BUILD_INTERVAL
set -euo pipefail

REPO_NAME=${REPO_NAME:-dsr-aur}
REPO_ROOT=${REPO_ROOT:-/srv/repo}
SOURCE_DIR=${SOURCE_DIR:-/src}
STATE_DIR=${STATE_DIR:-/var/lib/dsr-aur}
CACHE_DIR=${CACHE_DIR:-/var/cache/dsr-aur}
WORK_DIR=${WORK_DIR:-/tmp/build-repo}
BUILD_USER=${BUILD_USER:-builder}
BUILD_INTERVAL=${BUILD_INTERVAL:-6h}
KEYSERVER=${KEYSERVER:-hkps://keyserver.ubuntu.com}
SIGN=${SIGN:-1}
FORCE=${FORCE:-0}

ARCH=$(uname -m)
REPO_DIR=$REPO_ROOT/$ARCH
DB=$REPO_DIR/$REPO_NAME.db.tar.gz
SIGN_GNUPGHOME=$STATE_DIR/gnupg
NVCHECKER_KEYFILE=$STATE_DIR/nvchecker-keys.toml

# makepkg reads these from the environment, overriding makepkg.conf.
export PKGDEST=$WORK_DIR/out
export SRCDEST=$CACHE_DIR/sources
export CCACHE_DIR=$CACHE_DIR/ccache

SIGN_KEY=
PRUNE=1
SOURCES=()
FAILED=()
declare -A LOCAL_SOURCES=()

log() { printf '==> %s\n' "$*" >&2; }
warn() { printf '==> WARNING: %s\n' "$*" >&2; }

as_builder() { runuser -u "$BUILD_USER" -- "$@"; }

# The signing key lives in a root-only keyring that PKGBUILD code cannot read.
gpg_sign() { GNUPGHOME=$SIGN_GNUPGHOME gpg --batch --pinentry-mode loopback "$@"; }

# A broken CPU emulator makes tools crash, which the script would misread as "no match".
check_tools() {
  if ! { echo ok | grep -q ok && echo ok | sed -n /ok/p | awk '/ok/ { found = 1 } END { exit !found }'; }; then
    warn "Core tools crash on this host (broken CPU emulation?); aborting"
    exit 1
  fi
}

setup_system() {
  log "Updating build system"
  pacman -Sy --noconfirm --needed archlinux-keyring
  pacman -Su --noconfirm

  install -d "$REPO_DIR" "$STATE_DIR"
  install -d -o "$BUILD_USER" -g "$BUILD_USER" "$CACHE_DIR" "$SRCDEST" "$CCACHE_DIR"
  rm -rf "$WORK_DIR"
  install -d -o "$BUILD_USER" -g "$BUILD_USER" "$WORK_DIR" "$WORK_DIR/sources" "$PKGDEST"
}

setup_signing() {
  [[ $SIGN == 1 ]] || return 0
  install -d -m 700 "$SIGN_GNUPGHOME"
  if ! gpg_sign --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec'; then
    log "Generating repository signing key"
    gpg_sign --passphrase '' --quick-gen-key "$REPO_NAME repository signing key" ed25519 sign never
  fi
  SIGN_KEY=$(gpg_sign --list-secret-keys --with-colons | awk -F: '/^fpr/ { print $10; exit }')
  gpg_sign --armor --export "$SIGN_KEY" >"$REPO_ROOT/$REPO_NAME.asc"
  log "Signing with key $SIGN_KEY"
}

# Move the GitHub token into a root-only nvchecker keyfile, out of the build environment.
setup_nvchecker() {
  rm -f "$NVCHECKER_KEYFILE"
  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    (umask 077 && printf '[keys]\ngithub = "%s"\n' "$GITHUB_TOKEN" >"$NVCHECKER_KEYFILE")
  fi
  unset GITHUB_TOKEN
}

# Expose the repository to pacman so packages can depend on each other.
register_repo() {
  grep -q "^\[$REPO_NAME\]" /etc/pacman.conf && return 0
  [[ -e $REPO_DIR/$REPO_NAME.db ]] || return 0
  printf '\n[%s]\nSigLevel = Never\nServer = file://%s\n' "$REPO_NAME" "$REPO_DIR" >>/etc/pacman.conf
}

db_field() {
  [[ -e $DB ]] || return 0
  tar -xOf "$DB" --wildcards '*/desc' 2>/dev/null |
    awk -v field="%$1%" 'take { print; take = 0 } $0 == field { take = 1 }'
}

# Run repo-add or repo-remove against the database, signing it when a key is set.
repo_db() {
  local -a args=(--quiet)
  [[ -n $SIGN_KEY ]] && args+=(--sign --key "$SIGN_KEY")
  GNUPGHOME=$SIGN_GNUPGHOME "$1" "${args[@]}" "$DB" "${@:2}"
}

srcinfo_pkgnames() { sed -n 's/^pkgname = //p' <<<"$1"; }

# Fields of the pkgbase section, which precedes the first "pkgname =" line.
srcinfo_global() { sed -n '/^pkgname = /q; s/^[[:space:]]*'"$1"' = //p' <<<"$2"; }

is_vcs() { grep -Eq '^[[:space:]]*(function[[:space:]]+)?pkgver[[:space:]]*\(\)' PKGBUILD; }

is_published() {
  local list file
  [[ $FORCE == 1 ]] && return 1
  list=$(as_builder makepkg --packagelist) || return 1
  [[ -n $list ]] || return 1
  while read -r file; do
    [[ -e $REPO_DIR/${file##*/} ]] || return 1
  done <<<"$list"
}

import_keys() {
  local key asc
  for asc in keys/pgp/*.asc; do
    [[ -e $asc ]] || continue
    as_builder gpg --batch --quiet --import "$asc" || warn "Could not import $asc"
  done
  while read -r key; do
    [[ -n $key ]] || continue
    as_builder gpg --batch --list-keys "$key" &>/dev/null && continue
    as_builder gpg --batch --quiet --keyserver "$KEYSERVER" --recv-keys "$key" ||
      warn "Could not fetch PGP key $key"
  done < <(srcinfo_global validpgpkeys "$1")
}

# Dependencies are installed by root so the build user never needs sudo.
install_deps() {
  local field
  local -a deps
  mapfile -t deps < <(
    for field in depends makedepends checkdepends; do
      srcinfo_global "$field" "$1"
      srcinfo_global "${field}_$ARCH" "$1"
    done | sort -u
  )
  (( ${#deps[@]} )) || return 0
  pacman -Sy --noconfirm --needed --asdeps "${deps[@]}"
}

# Bump pkgver to the latest upstream version reported by .nvchecker.toml.
# Only local packages get here, so the nvchecker config is trusted and runs as root.
update_version() {
  local name=$1 srcinfo current latest
  local -a keys=()
  [[ -f .nvchecker.toml ]] || return 0
  [[ -f $NVCHECKER_KEYFILE ]] && keys=(-k "$NVCHECKER_KEYFILE")

  srcinfo=$(as_builder makepkg --printsrcinfo) || return 1
  current=$(srcinfo_global pkgver "$srcinfo")
  latest=$(nvchecker --logger json -c .nvchecker.toml "${keys[@]}" 2>/dev/null |
    jq -r 'select(.version != null) | .version' | head -n 1)
  if [[ -z $latest ]]; then
    warn "nvchecker found no upstream version for $name; keeping $current"
    return 0
  fi
  if [[ ! $latest =~ ^[[:alnum:]._+]+$ ]]; then
    warn "Upstream version '$latest' of $name is not a valid pkgver; keeping $current"
    return 0
  fi
  (( $(vercmp "$latest" "$current") > 0 )) || return 0

  log "Updating $name from $current to $latest"
  as_builder sed -i -e "s/^pkgver=.*/pkgver=$latest/" -e 's/^pkgrel=.*/pkgrel=1/' PKGBUILD &&
    as_builder updpkgsums >/dev/null
}

remove_new_deps() {
  local -a extra
  mapfile -t extra < <(comm -13 "$1" <(pacman -Qq | sort))
  (( ${#extra[@]} )) || return 0
  pacman -Rns --noconfirm "${extra[@]}" >/dev/null || warn "Could not remove build dependencies"
}

# Sign the built packages, move them into the repository and add them to the database.
publish() {
  local list file
  local -a added=()
  list=$(as_builder makepkg --packagelist) || return 1
  while read -r file; do
    [[ -e $file ]] || { warn "makepkg did not produce $file"; return 1; }
    if [[ -n $SIGN_KEY ]]; then
      gpg_sign --yes --detach-sign --no-armor --local-user "$SIGN_KEY" --output "$file.sig" "$file" || return 1
      mv -f "$file.sig" "$REPO_DIR/" || return 1
    fi
    mv -f "$file" "$REPO_DIR/" || return 1
    added+=("$REPO_DIR/${file##*/}")
  done <<<"$list"
  repo_db repo-add "${added[@]}" || return 1
  register_repo
}

# Runs inside "if", where errexit is ignored, so every step checks its own status.
build_package() {
  local name=$1 srcinfo deps_before=$WORK_DIR/deps-before
  cd "$WORK_DIR/sources/$name" || return 1
  if [[ -n ${LOCAL_SOURCES[$name]:-} ]] && ! is_vcs; then
    update_version "$name" || return 1
  fi
  srcinfo=$(as_builder makepkg --printsrcinfo) || return 1

  if ! is_vcs && is_published; then
    log "$name is up to date"
    return 0
  fi

  pacman -Qq | sort >"$deps_before" || return 1
  import_keys "$srcinfo"
  if ! install_deps "$srcinfo"; then
    remove_new_deps "$deps_before"
    return 1
  fi

  # VCS packages only know their real version after pkgver() runs.
  if is_vcs && as_builder makepkg --nobuild --noconfirm >/dev/null && is_published; then
    log "$name is up to date"
    remove_new_deps "$deps_before"
    return 0
  fi

  log "Building $name"
  if ! as_builder makepkg --noconfirm --cleanbuild --clean --force || ! publish; then
    remove_new_deps "$deps_before"
    return 1
  fi
  remove_new_deps "$deps_before"
}

# Fill $WORK_DIR/sources with AUR checkouts first (in aur.txt order), then local packages.
collect_sources() {
  local line name rev dir

  if [[ -f $SOURCE_DIR/aur.txt ]]; then
    while IFS= read -r line; do
      line=${line%%#*}
      line=${line//[[:space:]]/}
      [[ -n $line ]] || continue
      name=${line%%@*}
      rev=
      [[ $line == *@* ]] && rev=${line#*@}
      dir=$WORK_DIR/sources/$name
      if ! as_builder git clone --quiet "https://aur.archlinux.org/$name.git" "$dir" ||
        [[ ! -f $dir/PKGBUILD ]] ||
        { [[ -n $rev ]] && ! as_builder git -C "$dir" checkout --quiet "$rev"; }; then
        warn "Could not fetch AUR package $name${rev:+@$rev}"
        FAILED+=("$name")
        PRUNE=0
        continue
      fi
      SOURCES+=("$name")
    done <"$SOURCE_DIR/aur.txt"
  fi

  for dir in "$SOURCE_DIR"/pkgs/*/; do
    [[ -f $dir/PKGBUILD ]] || continue
    name=$(basename "$dir")
    if [[ -e $WORK_DIR/sources/$name ]]; then
      warn "$name is listed in aur.txt and pkgs/; using the AUR version"
      continue
    fi
    cp -r "$dir" "$WORK_DIR/sources/$name"
    chown -R "$BUILD_USER:$BUILD_USER" "$WORK_DIR/sources/$name"
    SOURCES+=("$name")
    LOCAL_SOURCES[$name]=1
  done
}

# Drop packages whose sources are gone and files the database no longer references.
prune() {
  local name pkg srcinfo file base
  local -a stale=()
  local -A known=() referenced=()

  if (( PRUNE )); then
    for name in "${SOURCES[@]}"; do
      if ! srcinfo=$(cd "$WORK_DIR/sources/$name" && as_builder makepkg --printsrcinfo); then
        PRUNE=0
        break
      fi
      while read -r pkg; do
        known[$pkg]=1
      done < <(srcinfo_pkgnames "$srcinfo")
    done
  fi

  if (( PRUNE )); then
    while read -r pkg; do
      [[ -n $pkg && -z ${known[$pkg]:-} ]] && stale+=("$pkg")
    done < <(db_field NAME)
    if (( ${#stale[@]} )); then
      log "Removing ${stale[*]}"
      repo_db repo-remove "${stale[@]}"
    fi
  fi

  while read -r file; do
    [[ -n $file ]] && referenced[$file]=1
  done < <(db_field FILENAME)
  for file in "$REPO_DIR"/*.pkg.tar.*; do
    [[ -e $file ]] || continue
    base=${file##*/}
    [[ -n ${referenced[${base%.sig}]:-} ]] || rm -f "$file"
  done
}

build_once() {
  local name

  install -d "$STATE_DIR"
  exec 9>"$STATE_DIR/build.lock"
  flock 9

  check_tools
  setup_system
  setup_signing
  setup_nvchecker
  register_repo
  collect_sources

  for name in "${SOURCES[@]}"; do
    if ! (build_package "$name"); then
      warn "Failed to build $name"
      FAILED+=("$name")
      PRUNE=0
    fi
  done

  prune
  rm -rf "$WORK_DIR"

  if (( ${#FAILED[@]} )); then
    warn "Failed: ${FAILED[*]}"
    return 1
  fi
  log "Repository is up to date"
}

case ${1:-once} in
  once) build_once ;;
  loop)
    while :; do
      "$0" once || warn "Build cycle finished with errors"
      log "Next build in $BUILD_INTERVAL"
      sleep "$BUILD_INTERVAL"
    done
    ;;
  *)
    echo "usage: ${0##*/} [once|loop]" >&2
    exit 2
    ;;
esac
