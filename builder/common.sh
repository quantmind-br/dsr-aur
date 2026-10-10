# Settings and helpers shared by dsr-build and dsr-publish (sourced, not executed).
# shellcheck shell=bash disable=SC2034  # variables are used by the scripts that source this file

REPO_NAME=${REPO_NAME:-dsr-aur}
REPO_ROOT=${REPO_ROOT:-/srv/repo}
EXCHANGE_DIR=${EXCHANGE_DIR:-/srv/exchange} # builder -> publisher; the builder can write it
CONTROL_DIR=${CONTROL_DIR:-/srv/control}    # publisher -> builder; read-only in the builder
SOURCE_DIR=${SOURCE_DIR:-/src}

ARCH=$(uname -m)
REPO_DIR=$REPO_ROOT/$ARCH
DB=$REPO_DIR/$REPO_NAME.db.tar.gz
INCOMING_DIR=$EXCHANGE_DIR/incoming
VERSIONS_FILE=$CONTROL_DIR/versions

NAME_RE='^[a-z0-9@_+][a-z0-9@._+-]*$'
PKGVER_RE='^[A-Za-z0-9._+]+$'
PKG_FILE_RE='^[a-z0-9@_+][a-z0-9@._+-]*-([0-9]+:)?[A-Za-z0-9._+]+-[0-9.]+-(x86_64|any)\.pkg\.tar\.(zst|xz)$'

PKGINFO_KEYS=' arch backup builddate checkdepend conflict depend group license makedepend optdepend packager pkgbase pkgdesc pkgname pkgver provides replaces size url xdata '

log() { printf '==> %s\n' "$*" >&2; }
warn() { printf '==> WARNING: %s\n' "$*" >&2; }

# A broken CPU emulator makes tools crash, which the scripts would misread as "no match".
check_tools() {
  if ! { echo ok | grep -q ok && echo ok | sed -n /ok/p | awk '/ok/ { found = 1 } END { exit !found }'; }; then
    warn "Core tools crash on this host (broken CPU emulation?); aborting"
    exit 1
  fi
}

# Print "name version filename" for each package in the database.
# Fails when the database exists but cannot be read or holds an incomplete entry, so callers
# never mistake that for "empty".
db_versions() {
  local entries
  [[ -e $DB ]] || return 0
  entries=$(tar -tf "$DB") || return 1
  grep -q '/desc$' <<<"$entries" || return 0
  tar -xOf "$DB" --wildcards '*/desc' | awk '
    function flush() {
      if (name != "" || version != "" || file != "") {
        if (name == "" || version == "" || file == "") bad = 1
        else print name, version, file
      }
      name = version = file = ""
    }
    $0 == "%FILENAME%" { flush(); getline file; next }
    $0 == "%NAME%" { getline name; next }
    $0 == "%VERSION%" { getline version; next }
    END { flush(); exit bad }'
}

# The database is gone although packages remain: a lost database, not an empty repository.
db_lost() {
  [[ ! -e $DB ]] && compgen -G "$REPO_DIR/*.pkg.tar.*" >/dev/null
}

# Run "$0 once" now and every $1 (sleep syntax). A stop signal waits for the running cycle.
run_loop() {
  local interval=$1 child=
  trap 'if [[ -n $child ]]; then kill -TERM "$child" 2>/dev/null; wait "$child"; fi; exit 0' TERM INT
  while :; do
    "$0" once &
    child=$!
    wait "$child" || warn "Cycle finished with errors"
    sleep "$interval" &
    child=$!
    wait "$child"
  done
}

# repo-add turns every .PKGINFO key into a shell variable (declare "$key=$value"), so a crafted
# key can overwrite repo-add's own variables or run code through an array subscript. PKGBUILD
# code runs inside makepkg and can write any .PKGINFO: accept only the keys makepkg writes.
pkginfo_is_safe() {
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == '#'* ]] && continue
    [[ $line =~ ^([a-z]+)\ =\ [[:print:]]*$ && $PKGINFO_KEYS == *" ${BASH_REMATCH[1]} "* ]] || return 1
  done <<<"$1"
}
