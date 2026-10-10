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
declare -A SOURCE_PATH=() IS_LOCAL=() PUBLISHED=() PUBLISHED_FILE=() UPSTREAM=()

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
  install -d -m 700 "$PRIVATE_DIR" "$PRIVATE_DIR/stage" "$PRIVATE_DIR/out" "$PRIVATE_DIR/known"
  install -d -o root -g root -m 755 "$WORK_DIR" "$WORK_DIR/sources" "$WORK_DIR/out" \
    "$CACHE_DIR" "$CACHE_DIR/sources" "$CACHE_DIR/ccache" "$CACHE_DIR/home"
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
    [[ -e $dir/$section.db ]] || continue
    printf '\n[%s]\nSigLevel = Never\nServer = file://%s\n' "$section" "$dir" >>/etc/pacman.conf
  done
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
    [[ -n ${PUBLISHED[$pkg]:-} && -f $REPO_DIR/${PUBLISHED_FILE[$pkg]} ]] || return 1
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
    if ! as_builder makepkg --nobuild --noconfirm >/dev/null || ! srcinfo=$(as_builder makepkg --printsrcinfo); then
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
  load_published || exit 1
  load_versions
  PHASE=sources
  collect_sources || exit 1
  register_repos
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
