#!/usr/bin/env bash
# Publish the batches dsr-build hands over: validate and sign packages, update the
# signed database, prune packages that left the sources, and resolve the latest
# upstream versions. This side never runs PKGBUILD code; it alone holds the signing
# key and the optional GitHub token.
#
# Usage: dsr-publish [once|loop|resign]
#   once      publish pending batches, refresh upstream versions when due, then exit
#   loop      run "once" now and again every $PUBLISH_INTERVAL
#   resign    re-sign all published files with the active key (after a key rotation)
#   versions  resolve upstream versions now and print them (used by local test builds)
set -euo pipefail
# shellcheck source=common.sh source-path=SCRIPTDIR
source "$(dirname "$(readlink -f "$0")")/common.sh"

STATE_DIR=${STATE_DIR:-/var/lib/dsr-aur}
PUBLISH_INTERVAL=${PUBLISH_INTERVAL:-1m}
VERSION_CHECK_MINUTES=${VERSION_CHECK_MINUTES:-60}
DELETE_GRACE_HOURS=${DELETE_GRACE_HOURS:-24}
ALLOW_EMPTY_PRUNE=${ALLOW_EMPTY_PRUNE:-0}
NOTIFY_URL=${NOTIFY_URL:-}
STALE_HOURS=${STALE_HOURS:-12}

FILES_DB=$REPO_DIR/$REPO_NAME.files.tar.gz
SIGN_GNUPGHOME=$STATE_DIR/gnupg
NVCHECKER_KEYFILE=$STATE_DIR/nvchecker-keys.toml
RECEIVE_DIR=${RECEIVE_DIR:-/var/tmp/dsr-publish}
SIGN_KEY=
PROCESSED=0     # a batch was consumed in this run
RUN_FAILED=()   # failures across every batch published in this run
RUN_REJECTED=()

gpg_sign() { GNUPGHOME=$SIGN_GNUPGHOME gpg --batch --pinentry-mode loopback "$@"; }

# The database is gone although the repository was initialized or packages remain: a lost
# database, not an empty repository. Publishing would create a new database listing only the
# new packages, and everything else would then look unreferenced.
db_lost() {
  [[ ! -e $DB ]] && { [[ -f $STATE_DIR/db-initialized ]] || compgen -G "$REPO_DIR/*.pkg.tar.*" >/dev/null; }
}

# POST a message to an ntfy topic URL (title and priority as ntfy headers).
send_notification() {
  [[ -n $NOTIFY_URL ]] || return 0
  curl -fsS --max-time 20 -H "Title: $1" -H "Priority: $3" -H "Tags: package" \
    --data-binary "$2" "$NOTIFY_URL" >/dev/null || { warn "Could not send a notification"; return 1; }
}

# Alerts are recorded first and delivered by flush_alerts, so a failed delivery is retried
# every cycle instead of being lost with the batch that raised it. In $STATE_DIR/alerts:
#   <key>.msg    current problem (title on the first line); re-sent daily while it lasts
#   <key>.sent   the problem was delivered
#   <key>.clear  recovery notice waiting for delivery
alert() {
  local dir=$STATE_DIR/alerts content=$2$'\n'$3
  [[ -n $NOTIFY_URL ]] || return 0
  install -d "$dir"
  rm -f "$dir/$1.clear"
  if [[ ! -f $dir/$1.msg || $(<"$dir/$1.msg") != "$content" ]]; then
    printf '%s' "$content" >"$dir/$1.msg"
    rm -f "$dir/$1.sent"
  fi
}

resolve() {
  local dir=$STATE_DIR/alerts
  [[ -f $dir/$1.msg ]] || return 0
  if [[ -f $dir/$1.sent ]]; then
    printf '%s\n%s' "$2" "$3" >"$dir/$1.clear"
  else
    # Never delivered: report the problem together with its recovery instead of dropping it.
    printf '%s\n%s\nWhile notifications were failing: %s' "$2" "$3" "$(tail -n +2 "$dir/$1.msg")" >"$dir/$1.clear"
  fi
  rm -f "$dir/$1.msg" "$dir/$1.sent"
}

flush_alerts() {
  local dir=$STATE_DIR/alerts file
  [[ -n $NOTIFY_URL && -d $dir ]] || return 0
  for file in "$dir"/*.msg; do
    [[ -f $file ]] || continue
    if [[ -f ${file%.msg}.sent && -z $(find "${file%.msg}.sent" -mmin +1440) ]]; then continue; fi
    send_notification "$(head -n 1 "$file")" "$(tail -n +2 "$file")" high && touch "${file%.msg}.sent"
  done
  for file in "$dir"/*.clear; do
    [[ -f $file ]] || continue
    send_notification "$(head -n 1 "$file")" "$(tail -n +2 "$file")" low && rm -f "$file"
  done
}

# The active key is SIGN_KEY_FPR when set; it must be in the keyring, so a lost keyring stops
# publishing (and alerts) instead of silently signing with a new key that clients reject.
# Without SIGN_KEY_FPR, a key is generated on the first run. Every public key in the keyring
# is exported, so clients can trust a new key before a rotation switches to it.
setup_signing() {
  local secrets
  install -d -m 700 "$SIGN_GNUPGHOME"
  secrets=$(gpg_sign --list-secret-keys --with-colons 2>/dev/null || true)
  if [[ -n ${SIGN_KEY_FPR:-} ]]; then
    if ! grep -q "^fpr:*:$SIGN_KEY_FPR:" <<<"$secrets"; then
      warn "Signing key $SIGN_KEY_FPR is not in $SIGN_GNUPGHOME; not publishing"
      alert signing-key "dsr-aur: signing key missing" "Key $SIGN_KEY_FPR is not in the publisher keyring. Restore it from the backup."
      flush_alerts
      exit 1
    fi
    SIGN_KEY=$SIGN_KEY_FPR
  else
    if ! grep -q '^sec' <<<"$secrets"; then
      log "Generating repository signing key"
      gpg_sign --passphrase '' --quick-gen-key "$REPO_NAME repository signing key" ed25519 sign never
    fi
    SIGN_KEY=$(gpg_sign --list-secret-keys --with-colons | awk -F: '/^fpr/ { print $10; exit }')
  fi
  [[ -n $SIGN_KEY ]] || { warn "No signing key"; exit 1; }
  resolve signing-key "dsr-aur: signing key back" "The publisher found its signing key again."
  gpg_sign --armor --export >"$REPO_ROOT/.$REPO_NAME.asc"
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
  local stamp=$STATE_DIR/versions-checked config raw status=0 name version
  local -a configs=() keys=() failed=()
  local -A versions=() resolved=()
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
  raw=$(timeout 10m nvchecker --logger json -c "$STATE_DIR/nvchecker.toml" "${keys[@]}" 2>&1) || status=$?

  # Success means every configured entry produced a valid pkgver in this run; anything else
  # (error, timeout, invalid or missing version) counts as a failure for that entry.
  while read -r name version; do
    [[ -n $name ]] || continue
    if [[ $name =~ $NAME_RE && $version =~ $PKGVER_RE ]]; then
      resolved[$name]=$version
    else
      warn "Ignoring upstream version '$version' of '$name' (not a valid pkgver)"
    fi
  done < <(jq -rR 'fromjson? | select(.name != null and .version != null) | "\(.name) \(.version)"' <<<"$raw")
  while read -r name; do
    if [[ -n $name && -z ${resolved[$name]:-} ]]; then failed+=("$name"); fi
  done < <(sed -n 's/^[[:space:]]*\[\([^]]*\)\][[:space:]]*$/\1/p' "$STATE_DIR/nvchecker.toml" | grep -v '^__' | sort -u)
  if (( status == 124 )); then warn "nvchecker timed out"; fi

  # Failed entries keep their previous version, so nothing is downgraded; say so instead of
  # silently freezing updates.
  if (( ${#failed[@]} )); then
    warn "Upstream version check failed for: ${failed[*]}"
    alert version-check "dsr-aur: version checks failing" "nvchecker failed for: ${failed[*]}. Their versions are frozen until it recovers."
  else
    resolve version-check "dsr-aur: version checks recovered" "Every upstream version check succeeded."
  fi

  if [[ -f $VERSIONS_FILE ]]; then
    while read -r name version || [[ -n $name ]]; do
      if [[ $name =~ $NAME_RE && $version =~ $PKGVER_RE ]]; then versions[$name]=$version; fi
    done <"$VERSIONS_FILE"
  fi
  for name in "${!resolved[@]}"; do versions[$name]=${resolved[$name]}; done
  for name in "${!versions[@]}"; do
    if [[ -f $SOURCE_DIR/pkgs/$name/.nvchecker.toml ]]; then echo "$name ${versions[$name]}"; fi
  done | sort >"$VERSIONS_FILE.tmp"
  mv -f "$VERSIONS_FILE.tmp" "$VERSIONS_FILE"
  touch "$stamp"
  (( ${#failed[@]} == 0 ))
}

# Run repo-add or repo-remove against the database, signed. Only this process writes the
# database and it holds the publish lock, so a leftover lock file is from a killed run.
repo_db() {
  rm -f "$DB.lck"
  GNUPGHOME=$SIGN_GNUPGHOME "$1" --quiet --sign --key "$SIGN_KEY" "${@:2}"
}

# True when $2 is a valid signature of $1 made by the active key.
signed_by_active() {
  gpg_sign --status-fd 1 --verify "$2" "$1" 2>/dev/null | grep -q "^\[GNUPG:\] VALIDSIG $SIGN_KEY "
}

# repo-add only warns when signing fails, and creates the .sig aliases only when it succeeds.
# Both databases must exist, carry a signature by the active key (this also re-signs them after
# a key rotation), and be reachable through the names pacman downloads.
verify_db_signatures() {
  local db alias
  [[ -e $DB ]] || return 0 # nothing published yet; a lost database is handled by db_lost
  for db in "$DB" "$FILES_DB"; do
    if [[ ! -e $db ]]; then
      warn "${db##*/} is missing"
      return 1
    fi
    if ! signed_by_active "$db" "$db.sig"; then
      warn "Signature of ${db##*/} is missing, invalid or by another key; re-signing"
      gpg_sign --yes --detach-sign --no-armor --local-user "$SIGN_KEY" --output "$db.sig.new" "$db" &&
        mv -f "$db.sig.new" "$db.sig" && signed_by_active "$db" "$db.sig" || return 1
    fi
    alias=${db%.tar.gz}
    [[ $(readlink "$alias") == "${db##*/}" ]] || ln -sfn "${db##*/}" "$alias" || return 1
    [[ $(readlink "$alias.sig") == "${db##*/}.sig" ]] || ln -sfn "${db##*/}.sig" "$alias.sig" || return 1
  done
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
  if db_lost; then
    warn "The database is missing but packages remain; not pruning"
    return 0
  fi
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

# Copy a batch out of the exchange volume before looking at it. The builder runs third-party
# code and controls that volume: it could swap a validated file for a symlink to one of the
# publisher's files. cp -P never follows symlinks, and only regular files of the copy are used.
# Returns 0 when the copy is usable, 3 when it holds symlinks (discard), 1 on copy errors.
receive_batch() {
  rm -rf "$RECEIVE_DIR" && install -d -m 700 "$RECEIVE_DIR" || return 1
  cp -R -P -- "$1" "$RECEIVE_DIR/batch" || return 1
  [[ -d $RECEIVE_DIR/batch && ! -L $RECEIVE_DIR/batch ]] || return 3
  # A symlinked "packages" directory would lead every later step back into the exchange volume.
  if [[ -n $(find "$RECEIVE_DIR/batch" -type l -print -quit) ]]; then
    warn "Batch ${1##*/} contains symlinks; discarding it"
    return 3
  fi
}

# Publish the batches in the incoming directory, oldest first. The builder can replace any
# path in the exchange volume, so work from inside the real incoming directory: after the cd,
# swapping an ancestor for a symlink cannot redirect the copy or the removal, and only names
# shaped like batch IDs are touched.
publish_incoming() {
  local name rc
  cd "$INCOMING_DIR" 2>/dev/null || return 0
  if [[ $(pwd -P) != "$INCOMING_DIR" ]]; then
    warn "$INCOMING_DIR resolves elsewhere; not touching it"
    cd /
    return 1
  fi
  for name in *; do
    [[ $name =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ && -d $name && ! -L $name ]] || continue
    rc=0
    receive_batch "./$name" || rc=$?
    if (( rc == 0 )); then
      process_batch "$RECEIVE_DIR/batch" "$name" || rc=$?
    fi
    if (( rc == 0 || rc == 3 )); then
      rm -rf -- "./$name"
      PROCESSED=1
    else
      # Later batches wait: applied after it, this older batch would undo their changes.
      warn "Batch $name failed; retrying it, and holding later batches, next cycle"
      cd /
      return 1
    fi
  done
  cd /
}

# Publish a received batch. Returns 0 when done, 3 when the batch is unusable (discard it),
# anything else to retry it next cycle.
process_batch() {
  local dir=$1 id=$2 key value file base prune=no
  local -a known=() added=() failed=() rejected=()
  local -A referenced=()
  if [[ ! -f $dir/manifest || -L $dir/manifest ]]; then
    warn "Batch $id has no manifest; discarding it"
    return 3
  fi
  while read -r key value || [[ -n $key ]]; do
    case $key in
      prune) if [[ $value == yes ]]; then prune=yes; fi ;;
      known) if [[ $value =~ $NAME_RE ]]; then known+=("$value"); fi ;;
      failed) failed+=("$value") ;;
      started | finished | built) ;;
      *) warn "Batch $id: unknown manifest entry '$key'" ;;
    esac
  done <"$dir/manifest"

  while read -r _ _ file; do
    if [[ -n $file ]]; then referenced[$file]=1; fi
  done < <(db_versions || true)
  for file in "$dir"/packages/*; do
    [[ -e $file ]] || continue
    if ! base=$(package_file_is_valid "$file"); then
      warn "Batch $id: rejecting ${file##*/} (not a valid package)"
      rejected+=("${file##*/}")
      continue
    fi
    # File names are immutable while the file exists (published or within the deletion grace
    # period): clients and Cloudflare may have cached it. Identical bytes are fine; a file the
    # database lists but the disk lost is restored.
    if [[ -e $REPO_DIR/$base || -L $REPO_DIR/$base ]]; then
      if ! cmp -s -- "$file" "$REPO_DIR/$base"; then
        warn "$base already exists with different content; bump pkgrel to ship a rebuild"
        rejected+=("$base")
        continue
      fi
      if [[ ! -f $REPO_DIR/$base.sig ]]; then
        gpg_sign --yes --detach-sign --no-armor --local-user "$SIGN_KEY" \
          --output "$REPO_DIR/$base.sig" "$REPO_DIR/$base" || return 1
      fi
      [[ -n ${referenced[$base]:-} ]] && continue
    else
      stage_package "$file" "$base" || { warn "Could not stage $base"; return 1; }
    fi
    added+=("$REPO_DIR/$base")
  done
  if (( ${#added[@]} )); then
    log "Publishing ${added[*]##*/}"
    repo_db repo-add --prevent-downgrade "$DB" "${added[@]}" || return 1
    verify_db_signatures || return 1
  fi
  # A rejected package may be the replacement of what pruning would remove.
  if [[ $prune == yes ]] && (( ${#failed[@]} + ${#rejected[@]} == 0 )); then
    prune_packages "${known[@]}" || return 1
  fi
  write_status "$dir/manifest" || warn "Could not write status.json"
  RUN_FAILED+=("${failed[@]}")
  RUN_REJECTED+=("${rejected[@]}")
}

# Dead man's switch: true when the builder's heartbeat (or its absence) is older than STALE_HOURS.
builder_silent() {
  local heartbeat=$EXCHANGE_DIR/heartbeat since
  if [[ -f $heartbeat && ! -L $heartbeat ]]; then
    rm -f "$STATE_DIR/no-heartbeat"
    since=$(stat -c %Y "$heartbeat")
  else
    [[ -f $STATE_DIR/no-heartbeat ]] || touch "$STATE_DIR/no-heartbeat"
    since=$(stat -c %Y "$STATE_DIR/no-heartbeat")
  fi
  (( $(date +%s) - since > STALE_HOURS * 3600 ))
}

# Delete package files the database stopped referencing, after a grace period, so
# clients holding a slightly older database can still download what it lists.
cleanup_unreferenced() {
  local listing state=$STATE_DIR/unreferenced now file base since
  local -A referenced=() first_seen=()
  db_lost && return 0
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
  local failed
  trap '' TERM INT # finish the cycle; the loop waits for it
  check_tools
  install -d "$STATE_DIR" "$REPO_DIR" "$CONTROL_DIR"
  exec 9>"$STATE_DIR/publish.lock"
  flock 9

  setup_signing
  check_versions || warn "Upstream version check failed"
  failed=0
  if db_lost; then
    warn "The database is missing; holding every batch until it is restored"
    alert database "dsr-aur: database missing" "$DB is missing although the repository was initialized. Publishing, pruning and deletions are on hold until it is restored."
  else
    resolve database "dsr-aur: database back" "The repository database is present again."
    publish_incoming || failed=1
  fi
  if [[ -e $DB ]]; then touch "$STATE_DIR/db-initialized"; fi
  rm -rf "$RECEIVE_DIR"
  if (( ${#RUN_FAILED[@]} + ${#RUN_REJECTED[@]} )); then
    alert build-failures "dsr-aur: build failures" \
      "Failed: ${RUN_FAILED[*]:-none}"$'\n'"Rejected: ${RUN_REJECTED[*]:-none}"$'\n'"https://aur.quantforge.com.br/status.json"
  elif (( PROCESSED )); then
    resolve build-failures "dsr-aur: builds recovered" "Every package built in the last cycle."
  fi
  # repo-add only warns when signing fails, and a failed check must not wait for the next
  # package to be retried.
  if ! verify_db_signatures; then
    alert signature "dsr-aur: database broken" "The repository database, its signature by the active key or its pacman aliases are broken and could not be repaired."
  else
    resolve signature "dsr-aur: database healthy" "The repository database and its signatures verify again."
  fi
  if (( failed )); then
    alert publish-error "dsr-aur: publishing failed" "A batch could not be published; see the dsr-publish logs."
  else
    resolve publish-error "dsr-aur: publishing recovered" "Pending batches were published."
  fi
  cleanup_unreferenced
  audit_repository

  # The builder touches its heartbeat at least every BUILD_TIMEOUT or BUILD_INTERVAL.
  if builder_silent; then
    alert stale "dsr-aur: builder silent" "No builder activity for over ${STALE_HOURS}h: it is stuck, crashed or out of disk."
  else
    resolve stale "dsr-aur: builder back" "Build batches are arriving again."
  fi
  flush_alerts
}

# Re-sign every package file (published or within the deletion grace period) and both
# databases with the active key (key rotation). Fails unless every signature verifies.
resign_all() {
  local listing file count=0 failures=0
  trap '' TERM INT
  check_tools
  exec 9>"$STATE_DIR/publish.lock"
  flock 9
  setup_signing
  listing=$(db_versions) || { warn "Cannot read the database"; exit 1; }
  while read -r _ _ file; do
    if [[ -n $file && ! -f $REPO_DIR/$file ]]; then
      warn "$file is listed but missing"
      failures=$((failures + 1))
    fi
  done <<<"$listing"
  for file in "$REPO_DIR"/*.pkg.tar.zst "$REPO_DIR"/*.pkg.tar.xz; do
    [[ -f $file && ! -L $file ]] || continue
    if gpg_sign --yes --detach-sign --no-armor --local-user "$SIGN_KEY" --output "$file.sig.new" "$file" &&
      mv -f "$file.sig.new" "$file.sig" && signed_by_active "$file" "$file.sig"; then
      count=$((count + 1))
    else
      warn "Could not re-sign ${file##*/}"
      failures=$((failures + 1))
    fi
  done
  verify_db_signatures || failures=$((failures + 1))
  if (( failures )); then
    warn "$failures problem(s) left; the repository is not fully signed by $SIGN_KEY"
    exit 1
  fi
  log "Re-signed $count package(s) and both databases with $SIGN_KEY"
}

# Once a day, check that every package the database lists is on disk, matches the checksum
# the database records, and carries a signature by the active key.
audit_repository() {
  local stamp=$STATE_DIR/audited file sum
  local -a problems=()
  if [[ -f $stamp && -z $(find "$stamp" -mmin +1440) ]]; then return 0; fi
  db_versions >/dev/null || return 0
  while read -r file sum; do
    [[ -n $file ]] || continue
    if [[ ! -f $REPO_DIR/$file ]]; then
      problems+=("$file (missing)")
    elif [[ $(sha256sum "$REPO_DIR/$file" | cut -d ' ' -f 1) != "$sum" ]]; then
      problems+=("$file (checksum differs from the database)")
    elif ! signed_by_active "$REPO_DIR/$file" "$REPO_DIR/$file.sig"; then
      problems+=("$file (signature missing, invalid or by another key)")
    fi
  done < <(db_checksums)
  touch "$stamp"
  if (( ${#problems[@]} )); then
    warn "Repository audit: ${problems[*]}"
    alert integrity "dsr-aur: repository audit failed" "$(printf '%s\n' "${problems[@]}")"
  else
    resolve integrity "dsr-aur: repository audit clean" "Every published package is present, intact and signed."
  fi
}

case ${1:-once} in
  once) publish_once ;;
  loop) run_loop "$PUBLISH_INTERVAL" ;;
  resign) resign_all ;;
  versions)
    check_tools
    install -d "$STATE_DIR" "$CONTROL_DIR"
    rm -f "$STATE_DIR/versions-checked"
    status=0
    check_versions || status=$?
    cat "$VERSIONS_FILE"
    exit "$status"
    ;;
  *)
    echo "usage: ${0##*/} [once|loop|resign|versions]" >&2
    exit 2
    ;;
esac
