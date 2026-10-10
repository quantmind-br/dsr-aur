#!/usr/bin/env bash
# Publish the batches dsr-build hands over: validate and sign packages, update the
# signed database, prune packages that left the sources, and resolve the latest
# upstream versions. This side never runs PKGBUILD code; it alone holds the signing
# key and the optional GitHub token.
#
# Usage: dsr-publish [once|loop]
#   once  publish pending batches, refresh upstream versions when due, then exit
#   loop  run "once" now and again every $PUBLISH_INTERVAL
set -euo pipefail
# shellcheck source=common.sh source-path=SCRIPTDIR
source "$(dirname "$(readlink -f "$0")")/common.sh"

STATE_DIR=${STATE_DIR:-/var/lib/dsr-aur}
PUBLISH_INTERVAL=${PUBLISH_INTERVAL:-1m}
VERSION_CHECK_MINUTES=${VERSION_CHECK_MINUTES:-60}
DELETE_GRACE_HOURS=${DELETE_GRACE_HOURS:-24}
ALLOW_EMPTY_PRUNE=${ALLOW_EMPTY_PRUNE:-0}

FILES_DB=$REPO_DIR/$REPO_NAME.files.tar.gz
SIGN_GNUPGHOME=$STATE_DIR/gnupg
NVCHECKER_KEYFILE=$STATE_DIR/nvchecker-keys.toml
SIGN_KEY=

gpg_sign() { GNUPGHOME=$SIGN_GNUPGHOME gpg --batch --pinentry-mode loopback "$@"; }

setup_signing() {
  install -d -m 700 "$SIGN_GNUPGHOME"
  if ! gpg_sign --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec'; then
    log "Generating repository signing key"
    gpg_sign --passphrase '' --quick-gen-key "$REPO_NAME repository signing key" ed25519 sign never
  fi
  SIGN_KEY=$(gpg_sign --list-secret-keys --with-colons | awk -F: '/^fpr/ { print $10; exit }')
  [[ -n $SIGN_KEY ]] || { warn "No signing key"; exit 1; }
  gpg_sign --armor --export "$SIGN_KEY" >"$REPO_ROOT/.$REPO_NAME.asc"
  if cmp -s "$REPO_ROOT/.$REPO_NAME.asc" "$REPO_ROOT/$REPO_NAME.asc"; then
    rm -f "$REPO_ROOT/.$REPO_NAME.asc"
  else
    mv -f "$REPO_ROOT/.$REPO_NAME.asc" "$REPO_ROOT/$REPO_NAME.asc"
  fi
}

# Resolve the newest upstream version of every local package with a .nvchecker.toml.
# Configs come from the image (git), never from the builder. A failed check keeps the
# previous answer, and dsr-build never builds below the published version anyway.
check_versions() {
  local stamp=$STATE_DIR/versions-checked config output name version
  local -a configs=() keys=()
  local -A versions=()
  if [[ -f $stamp && -z $(find "$stamp" -mmin +"$VERSION_CHECK_MINUTES") ]]; then
    return 0
  fi
  for config in "$SOURCE_DIR"/pkgs/*/.nvchecker.toml; do
    if [[ -f $config ]]; then configs+=("$config"); fi
  done
  (( ${#configs[@]} )) || { : >"$VERSIONS_FILE"; touch "$stamp"; return 0; }

  rm -f "$NVCHECKER_KEYFILE"
  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    (umask 077 && printf '[keys]\ngithub = "%s"\n' "$GITHUB_TOKEN" >"$NVCHECKER_KEYFILE")
    keys=(-k "$NVCHECKER_KEYFILE")
  fi
  cat "${configs[@]}" >"$STATE_DIR/nvchecker.toml"
  output=$(nvchecker --logger json -c "$STATE_DIR/nvchecker.toml" "${keys[@]}" 2>/dev/null |
    jq -r 'select(.name != null and .version != null) | "\(.name) \(.version)"') || true

  if [[ -f $VERSIONS_FILE ]]; then
    while read -r name version || [[ -n $name ]]; do
      if [[ $name =~ $NAME_RE && $version =~ $PKGVER_RE ]]; then versions[$name]=$version; fi
    done <"$VERSIONS_FILE"
  fi
  while read -r name version; do
    [[ -n $name ]] || continue
    if [[ $name =~ $NAME_RE && $version =~ $PKGVER_RE ]]; then
      versions[$name]=$version
    else
      warn "Ignoring upstream version '$version' of '$name' (not a valid pkgver)"
    fi
  done <<<"$output"
  for name in "${!versions[@]}"; do
    if [[ -f $SOURCE_DIR/pkgs/$name/.nvchecker.toml ]]; then echo "$name ${versions[$name]}"; fi
  done | sort >"$VERSIONS_FILE.tmp"
  mv -f "$VERSIONS_FILE.tmp" "$VERSIONS_FILE"
  touch "$stamp"
}

# Run repo-add or repo-remove against the database, signed. Only this process writes the
# database and it holds the publish lock, so a leftover lock file is from a killed run.
repo_db() {
  rm -f "$DB.lck"
  GNUPGHOME=$SIGN_GNUPGHOME "$1" --quiet --sign --key "$SIGN_KEY" "${@:2}"
}

# repo-add only warns when signing fails; check both signatures and re-sign if needed.
verify_db_signatures() {
  local db
  for db in "$DB" "$FILES_DB"; do
    [[ -e $db ]] || continue
    gpg_sign --verify "$db.sig" "$db" &>/dev/null && continue
    warn "Signature of ${db##*/} is missing or invalid; re-signing"
    gpg_sign --yes --detach-sign --no-armor --local-user "$SIGN_KEY" --output "$db.sig" "$db" &&
      gpg_sign --verify "$db.sig" "$db" &>/dev/null || return 1
  done
}

# Print the file name when the file is a regular package whose .PKGINFO matches its name.
validate_package() {
  local file=$1 base=${1##*/} info name version arch
  [[ $base =~ $PKG_FILE_RE && -f $file && ! -L $file ]] || return 1
  info=$(bsdtar -xOf "$file" .PKGINFO 2>/dev/null) || return 1
  name=$(sed -n 's/^pkgname = //p' <<<"$info")
  version=$(sed -n 's/^pkgver = //p' <<<"$info")
  arch=$(sed -n 's/^arch = //p' <<<"$info")
  [[ $base == "$name-$version-$arch.pkg.tar."* ]] || return 1
  printf '%s\n' "$base"
}

# Copy into the repository under a hidden name, sign, then rename into place.
stage_package() {
  local file=$1 base=$2 tmp=$REPO_DIR/.incoming-$2
  cp -- "$file" "$tmp" && chmod 644 "$tmp" &&
    gpg_sign --yes --detach-sign --no-armor --local-user "$SIGN_KEY" --output "$tmp.sig" "$tmp" &&
    mv -f "$tmp.sig" "$REPO_DIR/$base.sig" && mv -f "$tmp" "$REPO_DIR/$base"
}

prune_packages() {
  local listing name version file
  local -a stale=()
  local -A keep=()
  for name; do keep[$name]=1; done
  if ! listing=$(db_versions); then
    warn "Cannot read the database; not pruning"
    return 0
  fi
  if (( ${#keep[@]} == 0 )) && [[ -n $listing && $ALLOW_EMPTY_PRUNE != 1 ]]; then
    warn "The batch lists no packages at all; refusing to empty the repository (ALLOW_EMPTY_PRUNE=1 to allow)"
    return 0
  fi
  while read -r name version file; do
    if [[ -n $name && -z ${keep[$name]:-} ]]; then stale+=("$name"); fi
  done <<<"$listing"
  (( ${#stale[@]} )) || return 0
  log "Removing ${stale[*]}"
  repo_db repo-remove "$DB" "${stale[@]}" && verify_db_signatures
}

write_status() {
  local manifest=$1 count
  count=$(db_versions | grep -c . || true)
  jq -n --arg updated "$(date -u +%FT%TZ)" --arg key "$SIGN_KEY" --argjson packages "${count:-0}" \
    --arg started "$(sed -n 's/^started //p' "$manifest")" \
    --arg finished "$(sed -n 's/^finished //p' "$manifest")" \
    --argjson built "$(sed -n 's/^built //p' "$manifest" | jq -R . | jq -s .)" \
    --argjson failed "$(sed -n 's/^failed //p' "$manifest" | jq -R . | jq -s .)" \
    '{updated: $updated, signing_key: $key, packages: $packages,
      last_build: {started: $started, finished: $finished, built: $built, failed: $failed}}' \
    >"$REPO_ROOT/.status.json" && mv -f "$REPO_ROOT/.status.json" "$REPO_ROOT/status.json"
}

process_batch() {
  local dir=$1 id=${1##*/} key value file base prune=no
  local -a known=() added=()
  local -A referenced=()
  if [[ ! -f $dir/manifest ]]; then
    warn "Batch $id has no manifest; discarding it"
    rm -rf "$dir"
    return 1
  fi
  while read -r key value || [[ -n $key ]]; do
    case $key in
      prune) if [[ $value == yes ]]; then prune=yes; fi ;;
      known) if [[ $value =~ $NAME_RE ]]; then known+=("$value"); fi ;;
      started | finished | built | failed) ;;
      *) warn "Batch $id: unknown manifest entry '$key'" ;;
    esac
  done <"$dir/manifest"

  while read -r _ _ file; do
    if [[ -n $file ]]; then referenced[$file]=1; fi
  done < <(db_versions || true)
  for file in "$dir"/packages/*; do
    [[ -e $file ]] || continue
    if ! base=$(validate_package "$file"); then
      warn "Batch $id: rejecting ${file##*/} (not a valid package)"
      continue
    fi
    # Published file names are immutable: clients and Cloudflare may have cached them.
    if [[ -n ${referenced[$base]:-} ]]; then
      warn "$base is already published; bump pkgrel to ship a rebuild"
      continue
    fi
    stage_package "$file" "$base" || { warn "Could not stage $base"; return 1; }
    added+=("$REPO_DIR/$base")
  done
  if (( ${#added[@]} )); then
    log "Publishing ${added[*]##*/}"
    repo_db repo-add --prevent-downgrade "$DB" "${added[@]}" || return 1
    verify_db_signatures || return 1
  fi
  if [[ $prune == yes ]]; then
    prune_packages "${known[@]}" || return 1
  fi
  write_status "$dir/manifest"
  rm -rf "$dir"
}

# Delete package files the database stopped referencing, after a grace period, so
# clients holding a slightly older database can still download what it lists.
cleanup_unreferenced() {
  local listing state=$STATE_DIR/unreferenced now file base since
  local -A referenced=() first_seen=()
  if ! listing=$(db_versions); then
    warn "Cannot read the database; not cleaning up"
    return 0
  fi
  while read -r _ _ file; do
    if [[ -n $file ]]; then referenced[$file]=1; fi
  done <<<"$listing"
  if [[ -f $state ]]; then
    while read -r since base || [[ -n $since ]]; do
      if [[ $since =~ ^[0-9]+$ ]]; then first_seen[$base]=$since; fi
    done <"$state"
  fi
  now=$(date +%s)
  : >"$state.tmp"
  for file in "$REPO_DIR"/*.pkg.tar.*; do
    [[ -f $file ]] || continue
    base=${file##*/}
    [[ -n ${referenced[${base%.sig}]:-} ]] && continue
    since=${first_seen[$base]:-$now}
    if (( now - since >= DELETE_GRACE_HOURS * 3600 )); then
      log "Deleting unreferenced $base"
      rm -f -- "$file"
    else
      echo "$since $base" >>"$state.tmp"
    fi
  done
  mv -f "$state.tmp" "$state"
  find "$REPO_DIR" -maxdepth 1 -name '.incoming-*' -mmin +60 -delete
}

publish_once() {
  local dir
  trap '' TERM INT # finish the cycle; the loop waits for it
  check_tools
  install -d "$STATE_DIR" "$REPO_DIR" "$INCOMING_DIR"
  exec 9>"$STATE_DIR/publish.lock"
  flock 9

  setup_signing
  check_versions || warn "Upstream version check failed"
  for dir in "$INCOMING_DIR"/*/; do
    [[ -d $dir ]] || continue
    process_batch "${dir%/}" || warn "Batch ${dir%/} failed; retrying next cycle"
  done
  cleanup_unreferenced
}

case ${1:-once} in
  once) publish_once ;;
  loop) run_loop "$PUBLISH_INTERVAL" ;;
  *)
    echo "usage: ${0##*/} [once|loop]" >&2
    exit 2
    ;;
esac
