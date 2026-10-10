# Settings and helpers shared by dsr-build and dsr-publish (sourced, not executed).
# shellcheck shell=bash disable=SC2034  # variables are used by the scripts that source this file

REPO_NAME=${REPO_NAME:-dsr-aur}
REPO_ROOT=${REPO_ROOT:-/srv/repo}
EXCHANGE_DIR=${EXCHANGE_DIR:-/srv/exchange}
SOURCE_DIR=${SOURCE_DIR:-/src}

ARCH=$(uname -m)
REPO_DIR=$REPO_ROOT/$ARCH
DB=$REPO_DIR/$REPO_NAME.db.tar.gz
INCOMING_DIR=$EXCHANGE_DIR/incoming
VERSIONS_FILE=$EXCHANGE_DIR/versions

NAME_RE='^[a-z0-9@_+][a-z0-9@._+-]*$'
PKGVER_RE='^[A-Za-z0-9._+]+$'
PKG_FILE_RE='^[a-z0-9@_+][a-z0-9@._+-]*-([0-9]+:)?[A-Za-z0-9._+]+-[0-9.]+-(x86_64|any)\.pkg\.tar\.(zst|xz)$'

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
# Fails when the database exists but cannot be read, so callers never mistake that for "empty".
db_versions() {
  local entries
  [[ -e $DB ]] || return 0
  entries=$(tar -tf "$DB") || return 1
  grep -q '/desc$' <<<"$entries" || return 0
  tar -xOf "$DB" --wildcards '*/desc' | awk '
    function flush() { if (name != "") print name, version, file; name = version = file = "" }
    $0 == "%FILENAME%" { flush(); getline file; next }
    $0 == "%NAME%" { getline name; next }
    $0 == "%VERSION%" { getline version; next }
    END { flush() }'
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
