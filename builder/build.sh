#!/usr/bin/env bash
# Build outdated packages from $SOURCE_DIR and hand them to dsr-publish through
# $EXCHANGE_DIR. This side runs third-party code (PKGBUILDs, upstream build
# systems, dependency scriptlets), so it holds no signing key and no token.
#
# Usage: dsr-build [once|loop]
#   once  build every outdated package and write one batch for the publisher
#   loop  run "once" now and again every $BUILD_INTERVAL
set -euo pipefail
# shellcheck source=common.sh source-path=SCRIPTDIR
source "$(dirname "$(readlink -f "$0")")/common.sh"

CACHE_DIR=${CACHE_DIR:-/var/cache/dsr-aur}
WORK_DIR=${WORK_DIR:-/tmp/dsr-build}
PRIVATE_DIR=${PRIVATE_DIR:-/root/dsr-build}
BUILD_UID_BASE=${BUILD_UID_BASE:-200000}
ALLOW_UNPINNED_AUR=${ALLOW_UNPINNED_AUR:-0}
BUILD_INTERVAL=${BUILD_INTERVAL:-6h}
BUILD_TIMEOUT=${BUILD_TIMEOUT:-8h}
KEYSERVER=${KEYSERVER:-hkps://keyserver.ubuntu.com}
MIN_FREE_GB=${MIN_FREE_GB:-5}
STEP_TIMEOUT=${STEP_TIMEOUT:-1h}
HOME_CACHE_MAX_GB=${HOME_CACHE_MAX_GB:-5}
ABI_CHECK_HOURS=${ABI_CHECK_HOURS:-24}
# Remote mode (CI): the published repository is read over HTTPS instead of a local volume, and
# its database must carry a signature by SIGN_KEY_FPR.
REPO_URL=${REPO_URL:-}
SIGN_KEY_FPR=${SIGN_KEY_FPR:-}
FORCE=${FORCE:-0}
export CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-1G}

CYCLE_REPO=$PRIVATE_DIR/out # the cycle database sits beside the packages it lists
CYCLE_DB=$CYCLE_REPO/$REPO_NAME-cycle.db.tar.gz
DEP_RE='^[A-Za-z0-9@_+][A-Za-z0-9@._+-]*((<|>|<=|>=|=)[A-Za-z0-9._+:~-]+)?$'

SOURCES=()
FAILED=()
PRUNE=1
PHASE=start
STARTED=
BATCH_WRITTEN=0
declare -A SOURCE_PATH=() IS_LOCAL=() PUBLISHED=() PUBLISHED_FILE=() UPSTREAM=() ABI_BROKEN=()

BUILD_USER= # set per package by build_package

# Every step run as the build user is bounded; the main makepkg run has BUILD_TIMEOUT instead.
as_builder() { timeout --kill-after=1m "$STEP_TIMEOUT" runuser -u "$BUILD_USER" -- "$@"; }

# Kill everything the build user left behind, so nothing races the root steps that follow.
stop_build_user() { pkill -KILL -u "$BUILD_USER" 2>/dev/null || true; }

# Tell the publisher the builder is alive (its dead man's switch watches this file).
heartbeat() { touch "$EXCHANGE_DIR/heartbeat"; }

stop_all_build_users() {
  local users
  users=$(awk -F: '$1 ~ /^dsrb[0-9]+$/ { print $1 }' /etc/passwd | paste -sd, -)
  if [[ -n $users ]]; then pkill -KILL -u "$users" 2>/dev/null || true; fi
}

# Each package builds as its own user, so one PKGBUILD cannot touch another package's
# sources, caches or home. UIDs are allocated once and recorded in a root-only map on the
# cache volume, so they survive container rebuilds and never collide.
build_user_for() {
  local name=$1 map=$CACHE_DIR/uids uid='' max=$BUILD_UID_BASE entry id user
  if [[ -f $map ]]; then
    while read -r entry id || [[ -n $entry ]]; do
      [[ $entry =~ $NAME_RE && $id =~ ^[0-9]+$ ]] || continue
      if [[ $entry == "$name" ]]; then uid=$id; fi
      if (( id > max )); then max=$id; fi
    done <"$map"
  fi
  if [[ -z $uid ]]; then
    uid=$((max + 1))
    echo "$name $uid" >>"$map" || return 1
  fi
  user=dsrb$uid
  if getent passwd "$user" >/dev/null; then
    if [[ $(getent passwd "$user" | cut -d : -f 6) != "$CACHE_DIR/home/$name" ]]; then
      warn "$user does not belong to $name"
      return 1
    fi
  elif getent passwd "$uid" >/dev/null; then
    warn "UID $uid for $name is already taken"
    return 1
  else
    useradd --uid "$uid" --user-group --no-create-home --home-dir "$CACHE_DIR/home/$name" --shell /bin/bash "$user" || return 1
  fi
  printf '%s\n' "$user"
}

# Create a directory owned by the package's user, fixing ownership left by an older UID.
own_dir() {
  local dir
  for dir; do
    install -d -m 700 -o "$BUILD_USER" -g "$BUILD_USER" "$dir" || return 1
    if [[ -n $(find "$dir" ! -user "$BUILD_USER" -print -quit) ]]; then
      chown -R "$BUILD_USER:$BUILD_USER" "$dir" || return 1
    fi
  done
}

# Root-owned parents keep the build user from swapping the directories root reads from.
prepare() {
  stop_all_build_users
  rm -rf "$WORK_DIR" "$PRIVATE_DIR"
  install -d -m 700 "$PRIVATE_DIR" "$PRIVATE_DIR/stage" "$PRIVATE_DIR/out" "$PRIVATE_DIR/known" "$PRIVATE_DIR/abi" \
    "$PRIVATE_DIR/abi-unfixed"
  install -d -o root -g root -m 755 "$WORK_DIR" "$WORK_DIR/sources" "$WORK_DIR/out" \
    "$CACHE_DIR" "$CACHE_DIR/sources" "$CACHE_DIR/ccache" "$CACHE_DIR/home" "$CACHE_DIR/abi-rebuilt" \
    "$CACHE_DIR/langdirs"
  install -d "$INCOMING_DIR"
  # Batches a killed cycle never finished handing over.
  find "$INCOMING_DIR" -mindepth 1 -maxdepth 1 -name '.*' -mmin +1440 -exec rm -rf {} +
  # Under the cycle lock no pacman can be running: a lock file is left over from a kill.
  rm -f /var/lib/pacman/db.lck
  [[ -f /etc/pacman.conf.orig ]] || cp /etc/pacman.conf /etc/pacman.conf.orig
  cp /etc/pacman.conf.orig /etc/pacman.conf
  rm -rf /var/cache/pacman/pkg/*
}

setup_system() {
  log "Updating build system"
  timeout "$STEP_TIMEOUT" pacman -Sy --noconfirm --needed archlinux-keyring
  timeout "$STEP_TIMEOUT" pacman -Su --noconfirm
}

# Expose the published repository and this cycle's packages, so packages can depend on each other.
register_repos() {
  local section dir
  for section in "$REPO_NAME-cycle:$CYCLE_REPO" "$REPO_NAME:$REPO_DIR"; do
    dir=${section#*:}
    section=${section%%:*}
    grep -q "^\[$section\]" /etc/pacman.conf && continue
    [[ -e $dir/$section.db || -e $dir/$section.db.tar.gz ]] || continue
    if [[ -n $REPO_URL && $section == "$REPO_NAME" ]]; then
      # Packages come over HTTPS: pacman checks them against the pinned key.
      printf '\n[%s]\nSigLevel = Required\nServer = %s/%s\n' "$section" "$REPO_URL" "$ARCH" >>/etc/pacman.conf
    else
      printf '\n[%s]\nSigLevel = Never\nServer = file://%s\n' "$section" "$dir" >>/etc/pacman.conf
    fi
  done
}

# Remote mode: download the published database, accept it only with a signature by the pinned
# key (a tampered mirror must not make the builder skip or downgrade packages), and let pacman
# trust that key for the packages it installs from the repository.
fetch_remote_db() {
  local tmp code
  [[ -n $REPO_URL ]] || return 0
  if [[ ! $SIGN_KEY_FPR =~ ^[0-9A-F]{40}$ ]]; then
    warn "REPO_URL requires SIGN_KEY_FPR (40 hex digits)"
    return 1
  fi
  tmp=$(mktemp -d)
  if ! curl -fsSL --max-time 60 "$REPO_URL/$REPO_NAME.asc" -o "$tmp/key.asc" ||
    ! GNUPGHOME=$tmp gpg --batch --quiet --import "$tmp/key.asc" 2>/dev/null ||
    # The Arch image ships its keyring without a local signing key, which lsign needs.
    { [[ -z $(gpg --homedir /etc/pacman.d/gnupg --list-secret-keys 2>/dev/null) ]] &&
      ! pacman-key --init >/dev/null 2>&1; } ||
    ! pacman-key --add "$tmp/key.asc" >/dev/null 2>&1 ||
    ! pacman-key --lsign-key "$SIGN_KEY_FPR" >/dev/null 2>&1; then
    warn "Cannot import the repository key $SIGN_KEY_FPR"
    rm -rf "$tmp"
    return 1
  fi
  install -d "$REPO_DIR"
  code=$(curl -sSL --max-time 120 -o "$tmp/db" -w '%{http_code}' "$REPO_URL/$ARCH/$REPO_NAME.db") || code=000
  if [[ $code == 404 ]]; then
    log "No published database yet"
    rm -rf "$tmp"
    return 0
  fi
  if [[ $code != 200 ]] ||
    ! curl -fsSL --max-time 60 -o "$tmp/db.sig" "$REPO_URL/$ARCH/$REPO_NAME.db.sig" ||
    ! GNUPGHOME=$tmp gpg --batch --status-fd 1 --verify "$tmp/db.sig" "$tmp/db" 2>/dev/null |
      grep -q "^\[GNUPG:\] VALIDSIG $SIGN_KEY_FPR "; then
    warn "Cannot fetch a database signed by $SIGN_KEY_FPR from $REPO_URL"
    rm -rf "$tmp"
    return 1
  fi
  mv "$tmp/db" "$DB"
  rm -rf "$tmp"
}

# Path of a published package file for analysis; remote mode downloads it on demand.
published_path() {
  local file=$1
  if [[ ! -f $REPO_DIR/$file && -n $REPO_URL ]]; then
    curl -fsSL --max-time 600 -o "$REPO_DIR/.$file" "$REPO_URL/$ARCH/$file" && mv "$REPO_DIR/.$file" "$REPO_DIR/$file"
  fi
  [[ -f $REPO_DIR/$file ]] && printf '%s\n' "$REPO_DIR/$file"
}

load_published() {
  local listing name version file
  if ! listing=$(db_versions); then
    warn "Cannot read the published database"
    return 1
  fi
  while read -r name version file; do
    if [[ -n $name ]]; then
      PUBLISHED[$name]=$version
      PUBLISHED_FILE[$name]=$file
    fi
  done <<<"$listing"
}

# Published packages the current repositories can no longer satisfy. makepkg records the
# library sonames a package links against (depends = libicuuc.so=78-64); when Arch moves a
# library to a new soname, pacman cannot resolve that dependency any more, which is exactly
# when the package must be rebuilt. A library built here is seen once it is published.
find_abi_broken() {
  local name out deps
  grep -q "^\[$REPO_NAME\]" /etc/pacman.conf || return 0
  timeout "$STEP_TIMEOUT" pacman -Sy >/dev/null || return 0
  for name in "${!PUBLISHED[@]}"; do
    [[ $name == *-debug ]] && continue
    out=$(timeout "$STEP_TIMEOUT" pacman -Sp --noconfirm -- "$REPO_NAME/$name" 2>&1) && continue
    deps=$(sed -n "s/^:: unable to satisfy dependency '\([^']*\)' required by .*/\1/p" <<<"$out" | paste -sd ' ' -)
    if [[ -n $deps ]]; then
      ABI_BROKEN[$name]=$deps
      log "$name needs a rebuild: nothing provides $deps any more"
    fi
  done
}

# Sonames the ELF files of package $1 need from outside the package. The package came from a
# build, so it is unpacked and parsed as nobody.
list_needed() {
  local tmp status=0
  tmp=$(mktemp -d) || return 1
  chown nobody:nobody "$tmp" || { rm -rf "$tmp"; return 1; }
  # shellcheck disable=SC2016 # expanded by the inner shell
  runuser -u nobody -- bash -c '
    set -o pipefail
    mkdir "$1/root" && bsdtar -xf "$2" -C "$1/root" 2>/dev/null
    find "$1/root" -type f -print0 | xargs -0 -r readelf -d 2>/dev/null |
      sed -nr "s/.*Shared library: \[(.*)\].*/\1/p" | sort -u >"$1/needed"
    find "$1/root" -printf "%f\n" | sort -u >"$1/names"
    grep -vxF -f "$1/names" "$1/needed" || true
  ' _ "$tmp" "$1" || status=$?
  rm -rf "$tmp"
  return "$status"
}

# Published packages linking a soname that no repository ships any more. Most Arch packages
# do not declare lib: provides yet, so the pacman -Sp check misses their ABI breaks; this asks
# the files databases instead. It runs every ABI_CHECK_HOURS (the files databases are large),
# and the needed sonames of each published file are cached, since published files never change.
find_missing_sonames() {
  local stamp=$CACHE_DIR/abi-checked name file needed soname path
  local -A wanted=() present=() current=()
  if [[ -f $stamp && -z $(find "$stamp" -mmin +$((ABI_CHECK_HOURS * 60))) ]]; then return 0; fi
  timeout "$STEP_TIMEOUT" pacman -Fy >/dev/null || return 0
  install -d -m 755 "$CACHE_DIR/needed"
  for name in "${!PUBLISHED[@]}"; do
    file=${PUBLISHED_FILE[$name]}
    current[$file]=1
    needed=$CACHE_DIR/needed/$file
    if [[ ! -f $needed ]]; then
      if ! path=$(published_path "$file") || ! list_needed "$path" >"$needed"; then
        rm -f "$needed"
        continue
      fi
    fi
    # A NEEDED entry with a slash ($ORIGIN/../lib/libpython3.12.so.1.0 in a bundled CPython) is
    # loaded by path, never by soname lookup: no repository can ship it and nothing breaks.
    while read -r soname; do
      if [[ -n $soname && $soname != */* ]]; then wanted[$soname]+=" $name"; fi
    done <"$needed"
  done
  if (( ${#wanted[@]} )); then
    while IFS= read -r file; do
      present[${file##*/}]=1
    done < <(timeout "$STEP_TIMEOUT" pacman -F --machinereadable -- "${!wanted[@]}" 2>/dev/null | tr '\0' '\t' | cut -f 4)
    for soname in "${!wanted[@]}"; do
      [[ -n ${present[$soname]:-} ]] && continue
      for name in ${wanted[$soname]}; do
        ABI_BROKEN[$name]+="${ABI_BROKEN[$name]:+ }$soname"
        log "$name needs a rebuild: no repository ships $soname any more"
      done
    done
  fi
  # Cached lists of files no longer published are dropped.
  for needed in "$CACHE_DIR"/needed/*; do
    if [[ -e $needed && -z ${current[${needed##*/}]:-} ]]; then rm -f "$needed"; fi
  done
  touch "$stamp"
}

# Published packages left in the versioned directory of an older language runtime: once Arch
# ships Python 3.14, modules in usr/lib/python3.13 are never imported, though no soname changed.
# The same holds for Perl (usr/lib/perl5/5.42) and Ruby (usr/lib/ruby/gems/3.4.0). File lists
# are cached per published file.
find_stale_language_dirs() {
  local name file listing lang version current path
  local -A runtime=() published=()
  for lang in python perl ruby; do
    runtime[$lang]=$(pacman -Si "$lang" 2>/dev/null | sed -nE 's/^Version *: ([0-9]+\.[0-9]+).*/\1/p')
  done
  for name in "${!PUBLISHED[@]}"; do
    file=${PUBLISHED_FILE[$name]}
    published[$file]=1
    listing=$CACHE_DIR/langdirs/$file
    if [[ ! -f $listing ]]; then
      path=$(published_path "$file") || continue
      runuser -u nobody -- bsdtar -tf "$path" 2>/dev/null | sed -nE \
        -e 's#^usr/lib/python(3\.[0-9]+)/.*#python \1#p' \
        -e 's#^usr/lib/perl5/(5\.[0-9]+)/.*#perl \1#p' \
        -e 's#^usr/lib/ruby/gems/([0-9]+\.[0-9]+)\.[0-9]+/.*#ruby \1#p' | sort -u >"$listing"
    fi
    while read -r lang version; do
      current=${runtime[$lang]:-}
      if [[ -n $current && $version != "$current" ]]; then
        ABI_BROKEN[$name]+="${ABI_BROKEN[$name]:+ }$lang-$version-now-$current"
        log "$name needs a rebuild: it installs into $lang $version, Arch now ships $current"
      fi
    done <"$listing"
  done
  for listing in "$CACHE_DIR"/langdirs/*; do
    if [[ -e $listing && -z ${published[${listing##*/}]:-} ]]; then rm -f "$listing"; fi
  done
}

# Packages a client asked to rebuild (REBUILD="dsr-foo dsr-bar"), e.g. dsr-aur-check after it
# found an undefined symbol that no metadata reveals.
add_requested_rebuilds() {
  local name
  for name in ${REBUILD:-}; do
    if [[ $name =~ $NAME_RE && -n ${PUBLISHED[$name]:-} ]]; then
      ABI_BROKEN[$name]+="${ABI_BROKEN[$name]:+ }requested-by-client"
      log "$name needs a rebuild: requested by a client"
    fi
  done
}

# Latest upstream versions resolved by dsr-publish (which holds the GitHub token).
load_versions() {
  local name version
  [[ -f $VERSIONS_FILE ]] || return 0
  while read -r name version || [[ -n $name ]]; do
    if [[ $name =~ $NAME_RE && $version =~ $PKGVER_RE ]]; then UPSTREAM[$name]=$version; fi
  done <"$VERSIONS_FILE"
}

# Stage AUR clones (in aur.txt order) and local packages in root-only or root-owned places.
collect_sources() {
  local line name rev dir
  if [[ ! -f $SOURCE_DIR/aur.txt || ! -d $SOURCE_DIR/pkgs ]]; then
    warn "Source tree $SOURCE_DIR is incomplete"
    return 1
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    line=${line//[[:space:]]/}
    [[ -n $line ]] || continue
    name=${line%%@*}
    rev=
    [[ $line == *@* ]] && rev=${line#*@}
    dir=$PRIVATE_DIR/stage/$name
    if [[ -z $rev && $ALLOW_UNPINNED_AUR != 1 ]]; then
      warn "AUR package $name is not pinned: use $name@<commit> after reviewing the PKGBUILD"
      FAILED+=("$name")
      PRUNE=0
      continue
    fi
    if [[ ! $name =~ $NAME_RE || ( -n $rev && ! $rev =~ ^[0-9a-f]{7,40}$ ) ]] ||
      ! timeout 10m git clone --quiet "https://aur.archlinux.org/$name.git" "$dir" ||
      [[ ! -f $dir/PKGBUILD ]] ||
      { [[ -n $rev ]] && ! git -C "$dir" checkout --quiet "$rev"; }; then
      warn "Could not fetch AUR package $line"
      FAILED+=("$name")
      PRUNE=0
      continue
    fi
    rm -rf "$dir/.git"
    SOURCES+=("$name")
    SOURCE_PATH[$name]=$dir
  done <"$SOURCE_DIR/aur.txt"

  for dir in "$SOURCE_DIR"/pkgs/*/; do
    [[ -f $dir/PKGBUILD ]] || continue
    name=$(basename "$dir")
    if [[ ! $name =~ $NAME_RE ]]; then
      warn "Invalid package directory name $name"
      PRUNE=0
      continue
    fi
    if [[ -n ${SOURCE_PATH[$name]:-} ]]; then
      warn "$name is listed in aur.txt and pkgs/; using the AUR version"
      continue
    fi
    SOURCES+=("$name")
    SOURCE_PATH[$name]=${dir%/}
    IS_LOCAL[$name]=1
  done
}

enough_disk() {
  local free
  free=$(df --output=avail -BG "$CACHE_DIR" "$WORK_DIR" | tail -n +2 | tr -dc '0-9\n' | sort -n | head -n 1)
  (( free >= MIN_FREE_GB )) && return 0
  warn "Only ${free}G free (MIN_FREE_GB=$MIN_FREE_GB); skipping builds"
  return 1
}

srcinfo_pkgnames() { sed -n 's/^pkgname = //p' <<<"$1"; }

# Fields of the pkgbase section, which precedes the first "pkgname =" line.
srcinfo_global() { sed -n '/^pkgname = /q; s/^[[:space:]]*'"$1"' = //p' <<<"$2"; }

full_version() {
  local epoch
  epoch=$(srcinfo_global epoch "$1")
  printf '%s%s-%s\n' "${epoch:+$epoch:}" "$(srcinfo_global pkgver "$1")" "$(srcinfo_global pkgrel "$1")"
}

is_vcs() { grep -Eq '^[[:space:]]*(function[[:space:]]+)?pkgver[[:space:]]*\(\)' PKGBUILD; }

# Published means the database holds every pkgname at this version or newer, and the file it
# lists is on disk (a lost file is rebuilt and the publisher restores it).
is_published() {
  local version pkg
  [[ $FORCE == 1 ]] && return 1
  version=$(full_version "$1")
  while read -r pkg; do
    [[ -n ${PUBLISHED[$pkg]:-} ]] || return 1
    # A file the database lists but the disk lost is rebuilt (the publisher restores it). In
    # remote mode the publisher's daily audit watches the files instead.
    [[ -n $REPO_URL || -f $REPO_DIR/${PUBLISHED_FILE[$pkg]} ]] || return 1
    (( $(vercmp "${PUBLISHED[$pkg]}" "$version") >= 0 )) || return 1
  done < <(srcinfo_pkgnames "$1")
}

# Names the publisher must keep, including the implicit debug package.
record_known() {
  local name=$1 pkg
  local -a names=()
  while read -r pkg; do
    [[ $pkg =~ $NAME_RE ]] || { warn "Invalid pkgname '$pkg' in $name"; return 1; }
    names+=("$pkg")
  done < <(srcinfo_pkgnames "$2")
  (( ${#names[@]} )) || return 1
  names+=("$(srcinfo_global pkgbase "$2")-debug")
  printf '%s\n' "${names[@]}" >"$PRIVATE_DIR/known/$name"
}

# Raise pkgver to the newest upstream release, and never below the published version
# (a failed version check must not republish an older release). pkgrel stays as in git.
apply_version() {
  local name=$1 srcinfo current target candidate
  srcinfo=$(as_builder makepkg --printsrcinfo) || return 1
  current=$(srcinfo_global pkgver "$srcinfo")
  target=$current
  for candidate in "${UPSTREAM[$name]:-}" "$(sed 's/^[0-9]*://; s/-[^-]*$//' <<<"${PUBLISHED[$name]:-}")"; do
    if [[ -n $candidate ]] && (( $(vercmp "$candidate" "$target") > 0 )); then target=$candidate; fi
  done
  [[ $target == "$current" ]] && return 0
  log "Updating $name from $current to $target"
  as_builder sed -i "s/^pkgver=.*/pkgver=$target/" PKGBUILD && as_builder updpkgsums >/dev/null
}

# When the published version of this source lost a library it links against, rebuild it with a
# pkgrel just above the published one (1 -> 1.1 -> 1.2): pacman sees an upgrade, the file name
# is new, and a later pkgrel bump in git (2) still wins. Prints the updated .SRCINFO.
apply_abi_rebuild() {
  local name=$1 srcinfo=$2 pkg deps='' published='' rel target
  while read -r pkg; do
    if [[ -n ${ABI_BROKEN[$pkg]:-} ]]; then
      deps+="${deps:+ }${ABI_BROKEN[$pkg]}"
      published=${PUBLISHED[$pkg]}
    fi
  done < <(srcinfo_pkgnames "$srcinfo")
  if [[ -z $deps ]] || ! is_published "$srcinfo"; then
    printf '%s\n' "$srcinfo"
    return 0
  fi
  # A rebuild that did not cure the same break would repeat every cycle: report it instead.
  if [[ -f $CACHE_DIR/abi-rebuilt/$name && $(<"$CACHE_DIR/abi-rebuilt/$name") == "$published $deps" ]]; then
    warn "$name was already rebuilt for $deps and is still broken; not rebuilding it again"
    printf '%s\n' "$deps" >"$PRIVATE_DIR/abi-unfixed/$name"
    printf '%s\n' "$srcinfo"
    return 0
  fi
  rel=${published##*-}
  target=$(srcinfo_global pkgrel "$srcinfo")
  if (( $(vercmp "$rel" "$target") > 0 )); then target=$rel; fi
  if [[ $target =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    target=${BASH_REMATCH[1]}.$((BASH_REMATCH[2] + 1))
  else
    target=$target.1
  fi
  log "Rebuilding $name with pkgrel $target ($deps)"
  as_builder sed -i "s/^pkgrel=.*/pkgrel=$target/" PKGBUILD || return 1
  printf '%s\n' "$deps" >"$PRIVATE_DIR/abi/$name"
  srcinfo=$(as_builder makepkg --printsrcinfo) || return 1
  printf '%s %s\n' "$(full_version "$srcinfo")" "$deps" >"$CACHE_DIR/abi-rebuilt/$name"
  printf '%s\n' "$srcinfo"
}

import_keys() {
  local key asc
  for asc in keys/pgp/*.asc; do
    [[ -e $asc ]] || continue
    as_builder gpg --batch --quiet --import "$asc" || warn "Could not import $asc"
  done
  while read -r key; do
    [[ $key =~ ^[0-9A-Fa-f]{16,40}$ ]] || continue
    as_builder gpg --batch --list-keys "$key" &>/dev/null && continue
    as_builder gpg --batch --quiet --keyserver "$KEYSERVER" --recv-keys "$key" ||
      warn "Could not fetch PGP key $key"
  done < <(srcinfo_global validpgpkeys "$1")
}

# Root installs build dependencies, so the build user needs no sudo. .SRCINFO comes from
# PKGBUILD code: every entry must look like a dependency and "--" ends pacman's options.
install_deps() {
  local field dep
  local -a deps
  mapfile -t deps < <(
    for field in depends makedepends checkdepends; do
      srcinfo_global "$field" "$1"
      srcinfo_global "${field}_$ARCH" "$1"
    done | sort -u
  )
  for dep in "${deps[@]}"; do
    [[ $dep =~ $DEP_RE ]] || { warn "Invalid dependency '$dep'"; return 1; }
  done
  (( ${#deps[@]} )) || return 0
  timeout "$STEP_TIMEOUT" pacman -Syu --noconfirm --needed --asdeps -- "${deps[@]}"
}

remove_new_deps() {
  local -a extra
  mapfile -t extra < <(comm -13 "$PRIVATE_DIR/deps-before" <(pacman -Qq | sort))
  (( ${#extra[@]} )) || return 0
  timeout "$STEP_TIMEOUT" pacman -Rns --noconfirm "${extra[@]}" >/dev/null || warn "Could not remove build dependencies"
}

urldecode() { printf '%b' "${1//%/\\x}"; }

# Compare GitHub release downloads with the sha256 digest GitHub publishes. Any failure to
# check fails the package; it is retried next cycle. Assets without a digest (uploaded before
# GitHub recorded them) rely on the PKGBUILD checksums alone.
verify_release_digests() {
  local field entry url file repo tag asset json expected path actual
  while read -r entry; do
    url=${entry#*::}
    file=${url##*/}
    [[ $entry == *::* ]] && file=${entry%%::*}
    [[ $url =~ ^https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/([^/?#]+)$ ]] || continue
    repo=${BASH_REMATCH[1]} tag=${BASH_REMATCH[2]} asset=$(urldecode "${BASH_REMATCH[3]}")
    if [[ $file == */* || $file == . || $file == .. ]]; then
      warn "Unsafe source file name '$file'"
      return 1
    fi
    if ! json=$(curl -fsSL --max-time 60 -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$repo/releases/tags/$tag"); then
      warn "GitHub API unavailable for $repo $tag; will retry next cycle"
      return 1
    fi
    if ! jq -e --arg name "$asset" 'any(.assets[]; .name == $name)' <<<"$json" >/dev/null; then
      warn "Asset $asset is not part of $repo $tag"
      return 1
    fi
    expected=$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .digest // ""' <<<"$json")
    if [[ $expected != sha256:* ]]; then
      log "$asset has no published digest; relying on the PKGBUILD checksum"
      continue
    fi
    path=$SRCDEST/$file
    [[ -e $PWD/$file ]] && path=$PWD/$file # makepkg prefers a file beside the PKGBUILD
    actual=$(sha256sum "$path" | cut -d ' ' -f 1) || return 1
    if [[ ${expected#sha256:} != "$actual" ]]; then
      warn "$file does not match the sha256 GitHub publishes for $repo $tag/$asset"
      rm -f "$SRCDEST/$file" # a corrupt download heals on the next cycle; a swapped asset keeps failing
      return 1
    fi
    log "$file matches the GitHub release digest"
  done < <(for field in source "source_$ARCH"; do srcinfo_global "$field" "$1"; done)
}

# Copy the built packages out of the build user's reach and into this cycle's repository.
collect_outputs() {
  local list file base
  local -a added=()
  list=$(as_builder makepkg --packagelist) || return 1
  stop_build_user
  while read -r file; do
    base=${file##*/}
    if [[ $file != "$PKGDEST/$base" || ! $base =~ $PKG_FILE_RE ]]; then
      warn "Unexpected package path '$file'"
      return 1
    fi
    if [[ ! -f $file || -L $file || $(stat -c %h "$file") != 1 ]]; then
      warn "$base is not a regular package file"
      return 1
    fi
    if ! package_file_is_valid "$file" >/dev/null; then
      warn "$base has a .PKGINFO that repo-add cannot read safely or that does not match its name"
      return 1
    fi
    install -m 644 "$file" "$PRIVATE_DIR/out/$base" || return 1
    added+=("$PRIVATE_DIR/out/$base")
  done <<<"$list"
  (( ${#added[@]} )) || return 1
  repo-add --quiet "$CYCLE_DB" "${added[@]}" || return 1
  register_repos
}

# Keep only the downloads the current sources still use.
trim_source_cache() {
  local field entry name path
  local -A keep=()
  while read -r entry; do
    if [[ $entry == *::* ]]; then
      name=${entry%%::*}
    else
      name=${entry%%#*}
      name=${name%%\?*}
      name=${name##*/}
      [[ $entry =~ ^[a-z]+\+ ]] && name=${name%.git}
    fi
    keep[$name]=1
  done < <(for field in source "source_$ARCH"; do srcinfo_global "$field" "$1"; done)
  for path in "$SRCDEST"/* "$SRCDEST"/.[!.]*; do
    [[ -e $path || -L $path ]] || continue
    [[ -n ${keep[${path##*/}]:-} ]] || rm -rf -- "$path"
  done
}

# Runs in a subshell inside "||", where errexit is ignored: every step checks its status.
# Returns 0 when built or up to date, 2 when dependencies could not be installed (retried
# after other packages are built), 1 on any other failure.
build_package() {
  local name=$1 dir=$WORK_DIR/sources/$1 srcinfo
  export PKGDEST=$WORK_DIR/out/$name SRCDEST=$CACHE_DIR/sources/$name CCACHE_DIR=$CACHE_DIR/ccache/$name
  BUILD_USER=$(build_user_for "$name") || return 1
  rm -rf "$dir" "$PKGDEST" || return 1
  cp -r "${SOURCE_PATH[$name]}" "$dir" || return 1
  rm -rf "$dir/src" "$dir/pkg" "$dir"/*.pkg.tar.*
  chown -R "$BUILD_USER:$BUILD_USER" "$dir" && chmod 700 "$dir" || return 1
  # Tool caches in the home (npm, cargo, go) are dropped when they outgrow their share.
  if [[ -d $CACHE_DIR/home/$name ]] &&
    (( $(du -s --block-size=1G "$CACHE_DIR/home/$name" | cut -f 1) > HOME_CACHE_MAX_GB )); then
    rm -rf "${CACHE_DIR:?}/home/${name:?}"
  fi
  own_dir "$PKGDEST" "$SRCDEST" "$CCACHE_DIR" "$CACHE_DIR/home/$name" || return 1
  cd "$dir" || return 1

  if [[ -n ${IS_LOCAL[$name]:-} ]] && ! is_vcs; then
    apply_version "$name" || return 1
  fi
  srcinfo=$(as_builder makepkg --printsrcinfo) || return 1
  if ! is_vcs; then
    srcinfo=$(apply_abi_rebuild "$name" "$srcinfo") || return 1
  fi
  record_known "$name" "$srcinfo" || return 1
  if ! is_vcs && is_published "$srcinfo"; then
    log "$name is up to date"
    return 0
  fi

  pacman -Qq | sort >"$PRIVATE_DIR/deps-before" || return 1
  import_keys "$srcinfo"
  if ! install_deps "$srcinfo"; then
    stop_build_user
    remove_new_deps
    return 2
  fi

  # VCS packages only know their real version after pkgver() runs.
  if is_vcs; then
    if ! as_builder makepkg --nobuild --noconfirm >/dev/null || ! srcinfo=$(as_builder makepkg --printsrcinfo) ||
      ! srcinfo=$(apply_abi_rebuild "$name" "$srcinfo"); then
      stop_build_user
      remove_new_deps
      return 1
    fi
    if is_published "$srcinfo"; then
      log "$name is up to date"
      stop_build_user
      remove_new_deps
      return 0
    fi
  fi

  log "Building $name"
  if ! as_builder makepkg --verifysource --noconfirm >/dev/null ||
    ! verify_release_digests "$srcinfo" ||
    ! timeout --kill-after=1m "$BUILD_TIMEOUT" runuser -u "$BUILD_USER" -- \
      makepkg --noconfirm --cleanbuild --clean --force; then
    stop_build_user
    remove_new_deps
    return 1
  fi
  stop_build_user
  if ! collect_outputs; then
    remove_new_deps
    return 1
  fi
  remove_new_deps
  trim_source_cache "$srcinfo"
}

# Build in passes: a package whose dependencies are missing waits for the others.
build_all() {
  local name rc progress
  local -a pending=("${SOURCES[@]}") next
  while (( ${#pending[@]} )); do
    next=()
    progress=0
    for name in "${pending[@]}"; do
      heartbeat
      if ! enough_disk; then
        FAILED+=("$name")
        PRUNE=0
        continue
      fi
      rc=0
      (build_package "$name") || rc=$?
      case $rc in
        0) progress=1 ;;
        2) next+=("$name") ;;
        *)
          warn "Failed to build $name"
          FAILED+=("$name")
          PRUNE=0
          ;;
      esac
    done
    if (( ${#next[@]} && !progress )); then
      for name in "${next[@]}"; do warn "Dependencies of $name cannot be installed"; done
      FAILED+=("${next[@]}")
      PRUNE=0
      break
    fi
    pending=("${next[@]}")
  done
}

# Drop cache directories of packages that left the sources (and the old flat layout).
trim_caches() {
  local path
  local -A current=()
  for path in "${SOURCES[@]}" "${FAILED[@]}"; do current[$path]=1; done
  for path in "$CACHE_DIR"/sources/* "$CACHE_DIR"/ccache/* "$CACHE_DIR"/home/*; do
    [[ -e $path || -L $path ]] || continue
    [[ -d $path && ! -L $path && -n ${current[${path##*/}]:-} ]] || rm -rf -- "$path"
  done
}

# Hand the packages and the cycle's outcome to the publisher. The rename makes it atomic.
write_batch() {
  local id file name
  id=$(date -u +%Y%m%dT%H%M%SZ)-$$
  install -d "$INCOMING_DIR/.$id/packages"
  for file in "$PRIVATE_DIR"/out/*.pkg.tar.*; do
    if [[ -e $file ]]; then cp -- "$file" "$INCOMING_DIR/.$id/packages/"; fi
  done
  {
    echo "started $STARTED"
    echo "finished $(date -u +%FT%TZ)"
    echo "prune $( (( PRUNE )) && echo yes || echo no)"
    for name in "${SOURCES[@]}"; do
      if [[ -f $PRIVATE_DIR/known/$name ]]; then sed 's/^/known /' "$PRIVATE_DIR/known/$name"; fi
    done
    for name in "${FAILED[@]}"; do echo "failed $name"; done
    for file in "$PRIVATE_DIR"/out/*.pkg.tar.*; do
      if [[ -e $file ]]; then echo "built ${file##*/}"; fi
    done
    for file in "$PRIVATE_DIR"/abi/*; do
      if [[ -f $file ]]; then echo "abi ${file##*/} $(<"$file")"; fi
    done
    for file in "$PRIVATE_DIR"/abi-unfixed/*; do
      if [[ -f $file ]]; then echo "failed ${file##*/}-still-broken-after-rebuild"; fi
    done
  } >"$INCOMING_DIR/.$id/manifest"
  mv "$INCOMING_DIR/.$id" "$INCOMING_DIR/$id"
  BATCH_WRITTEN=1
  log "Handed batch $id to the publisher"
}

# A cycle that dies before handing over its batch still hands over the failure, so the
# publisher alerts (the heartbeat alone would look healthy while every cycle fails).
report_abort() {
  local status=$?
  (( BATCH_WRITTEN )) && return
  # Stopped by a redeploy or "docker stop": not a failure, the next cycle reruns.
  [[ -e $STOP_MARKER ]] && return
  warn "Cycle aborted during $PHASE"
  FAILED+=("cycle-aborted-in-$PHASE")
  PRUNE=0
  write_batch || true
  exit "$status"
}

build_once() {
  local name
  STARTED=$(date -u +%FT%TZ)
  check_tools
  exec 9>/run/dsr-build.lock
  flock 9
  trap report_abort EXIT

  PHASE=prepare
  prepare
  heartbeat
  PHASE=system-update
  setup_system
  PHASE=database
  fetch_remote_db || exit 1
  load_published || exit 1
  load_versions
  PHASE=sources
  collect_sources || exit 1
  register_repos
  find_abi_broken
  find_missing_sonames
  find_stale_language_dirs
  add_requested_rebuilds
  PHASE=build
  build_all
  # Without srcinfo for every source the publisher cannot tell what to keep.
  for name in "${SOURCES[@]}"; do
    [[ -f $PRIVATE_DIR/known/$name ]] || PRUNE=0
  done
  PHASE=handover
  trim_caches
  write_batch
  heartbeat
  stop_all_build_users
  rm -rf "$WORK_DIR"

  if (( ${#FAILED[@]} )); then
    warn "Failed: ${FAILED[*]}"
    return 1
  fi
  log "Build cycle finished"
}

case ${1:-once} in
  once) build_once ;;
  loop) run_loop "$BUILD_INTERVAL" ;;
  *)
    echo "usage: ${0##*/} [once|loop]" >&2
    exit 2
    ;;
esac
