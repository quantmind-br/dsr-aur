#!/usr/bin/env bash
# Verify an installed package on the Hyprland desktop: ELF libraries, desktop
# entries, icons, and a real launch with window, class, screenshot and log checks.
#
# Usage: verify-install.sh <pkgname> [--no-launch] [--wait <seconds>]
# Exit:  0 when every check passed, 1 when one failed, 3 when none failed but some were
#        skipped (inconclusive: e.g. a locked screen hid the rendering check).
set -uo pipefail

usage() { echo "usage: verify-install.sh <pkgname> [--no-launch] [--wait <seconds>]" >&2; exit 2; }
pkg=${1:-}
[[ -n $pkg ]] || usage
shift
launch=1
wait_s=25
while (( $# )); do
  case $1 in
    --no-launch) launch=0 ;;
    --wait) wait_s=${2:?}; shift ;;
    *) usage ;;
  esac
  shift
done

failures=0
skipped=0
sid=

# Kill the launched app's session, also when this script is interrupted.
stop_session() {
  [[ -n $sid ]] || return 0
  pkill -TERM -s "$sid" 2>/dev/null
  sleep 1
  pkill -KILL -s "$sid" 2>/dev/null
  sid=
}
trap stop_session EXIT
trap 'stop_session; exit 130' INT TERM
ok() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }
info() { printf '  info  %s\n' "$*"; }
skip() { printf '  SKIP  %s\n' "$*"; skipped=$((skipped + 1)); }

pacman -Q "$pkg" &>/dev/null || { echo "$pkg is not installed" >&2; exit 2; }
mapfile -t files < <(pacman -Qlq "$pkg" | grep -v '/$')
workdir=$(mktemp -d "/tmp/verify-$pkg.XXXXXX")
echo "== $(pacman -Q "$pkg")  (artifacts in $workdir)"

is_elf() { [[ -f $1 && $(head -c 4 "$1" 2>/dev/null | od -An -c | tr -d ' ') == 177ELF ]]; }
unresolved() { ldd "$1" 2>/dev/null | awk '/=> not found/ { print $1 }'; }

# Entry points: ELF files in /usr/bin and the targets that /usr/bin wrappers exec.
echo "== Libraries"
declare -A entry=()
for f in "${files[@]}"; do
  [[ $f == /usr/bin/* && -f $f ]] || continue
  if is_elf "$f"; then
    entry[$f]=1
  else
    while read -r target; do
      is_elf "$target" && entry[$target]=1
    done < <(grep -oE '^[[:space:]]*exec[[:space:]]+"?/[^" ]+' "$f" | grep -oE '/[^" ]+$')
  fi
done
for f in "${!entry[@]}"; do
  libs=$(unresolved "$f" | paste -sd ' ' -)
  if [[ -n $libs ]]; then fail "$f needs $libs"; else ok "$f resolves all libraries"; fi
done
(( ${#entry[@]} )) || info "no ELF entry point found in /usr/bin"

# Bundled helpers and plugins often reference libraries they never load: report, do not fail.
bundled=()
for f in "${files[@]}"; do
  [[ -z ${entry[$f]:-} ]] && is_elf "$f" && [[ -n $(unresolved "$f") ]] && bundled+=("$f")
done
if (( ${#bundled[@]} )); then
  info "${#bundled[@]} other ELF file(s) with unresolved libraries (matters only if the app loads them):"
  for f in "${bundled[@]:0:5}"; do info "  $f: $(unresolved "$f" | paste -sd ' ' -)"; done
fi

echo "== Desktop entries"
mapfile -t desktops < <(printf '%s\n' "${files[@]}" | grep -E '^/usr/share/applications/.+\.desktop$')
(( ${#desktops[@]} )) || info "no .desktop file (expected only for CLI tools)"

entry_value() { sed -n '/^\[Desktop Entry\]/,/^\[/ s/^'"$2"'=//p' "$1" | head -n 1; }

resolve_icon() {
  local icon=$1
  if [[ $icon == /* ]]; then
    [[ -f $icon ]] && echo "$icon"
    return
  fi
  find /usr/share/icons/hicolor /usr/share/pixmaps \( -name "$icon.svg" -o -name "$icon.png" -o -name "$icon.xpm" \) 2>/dev/null | head -n 1
}

for d in "${desktops[@]}"; do
  if out=$(desktop-file-validate "$d" 2>&1); then
    ok "$(basename "$d") is valid"
    [[ -n $out ]] && sort -u <<<"$out" | while read -r line; do info "${line#"$d": }"; done
  else
    fail "$(basename "$d"): $out"
  fi
  cmd=$(entry_value "$d" Exec | sed -E 's/ ?%[fFuUdDnNickvm]//g')
  bin=${cmd%% *}
  bin=${bin//\"/}
  if [[ $bin == /* && -x $bin ]] || command -v "$bin" &>/dev/null; then ok "Exec $bin exists"; else fail "Exec $bin not found"; fi
  icon=$(entry_value "$d" Icon)
  if [[ -z $icon ]]; then
    fail "Icon missing"
  elif path=$(resolve_icon "$icon") && [[ -n $path ]]; then
    ok "Icon $icon -> $path"
  else
    fail "Icon $icon not found in hicolor or pixmaps"
  fi
  [[ -n $(entry_value "$d" StartupWMClass) ]] || fail "StartupWMClass missing (launcher cannot match the window)"
done

# Launch the entry's Exec in its own session and check its Hyprland window.
launch_and_check() {
  local d=$1 cmd wmclass workpath log client pids class address geometry i
  cmd=$(entry_value "$d" Exec | sed -E 's/ ?%[fFuUdDnNickvm]//g')
  wmclass=$(entry_value "$d" StartupWMClass)
  workpath=$(entry_value "$d" Path)
  log=$workdir/app.log
  if [[ $(entry_value "$d" DBusActivatable) == true ]]; then
    info "DBusActivatable=true: launchers may start it over D-Bus instead of Exec"
  fi
  if [[ $(entry_value "$d" Terminal) == true ]]; then
    skip "Terminal=true: launch it from the launcher to check the terminal integration"
    return
  fi

  # shellcheck disable=SC2016 # $1 expands in the inner shell
  setsid sh -c 'cd "${1:-.}" && exec '"$cmd" sh "$workpath" >"$log" 2>&1 </dev/null &
  sid=$!
  client=
  for ((i = 0; i < wait_s * 2; i++)); do
    sleep 0.5
    pids=$(ps -o pid= -s "$sid" 2>/dev/null | tr -d ' ' | paste -sd, -)
    [[ -n $pids ]] || break
    client=$(hyprctl clients -j | jq -c --arg pids "$pids" \
      '($pids | split(",") | map(tonumber)) as $p | map(select(.pid as $x | $p | index($x))) | first // empty')
    [[ -n $client ]] && break
  done

  if [[ -z $client && -z $pids ]]; then
    fail "process exited before showing a window (crash, or a single-instance app already running); log tail:"
    tail -n 5 "$log" | sed 's/^/        /'
  elif [[ -z $client ]]; then
    fail "no window within ${wait_s}s"
  else
    class=$(jq -r .class <<<"$client")
    ok "window mapped: class=$class title=$(jq -r .title <<<"$client")"
    if [[ -n $wmclass && $class != "$wmclass" ]]; then
      fail "StartupWMClass=$wmclass but the window class is $class"
    fi
    if [[ $(basename "$d" .desktop) != "$class" ]]; then
      info "desktop file is $(basename "$d"); name it $class.desktop unless the class is generic (electron, java, python3)"
    fi
    address=$(jq -r .address <<<"$client")
    sleep 3
    hyprctl dispatch focuswindow "address:$address" >/dev/null
    sleep 1
    client=$(hyprctl clients -j | jq -c --arg a "$address" 'map(select(.address == $a)) | first // empty')
    if [[ -z $client ]]; then
      fail "window disappeared after mapping (crash?)"
    else
      geometry=$(jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"' <<<"$client")
      if [[ $(dms ipc call lock isLocked 2>/dev/null) == true ]]; then
        skip "screen is locked: no screenshot; rerun after unlocking to check rendering"
      elif grim -g "$geometry" "$workdir/window.png" 2>/dev/null; then
        info "screenshot: $workdir/window.png (inspect it: blank or black means a rendering problem)"
      else
        skip "grim could not capture the window; rendering not checked"
      fi
      hyprctl dispatch closewindow "address:$address" >/dev/null
      sleep 2
    fi
  fi
  stop_session

  local pattern='error while loading shared libraries|cannot open shared object|Segmentation fault|core dumped|Illegal instruction|GPU process (isn.t usable|exited unexpectedly)|Failed to create GBM|EGL_BAD|Gdk-ERROR|Could not (load|find) the Qt platform plugin|Failed to connect to Wayland|Unable to init server'
  if grep -qiE "$pattern" "$log"; then
    fail "crash signatures in $log:"
    grep -iE "$pattern" "$log" | head -n 10 | sed 's/^/        /'
  else
    ok "no crash signatures in log ($log)"
  fi
}

if (( launch && ${#desktops[@]} )); then
  echo "== Launch"
  if [[ -z ${WAYLAND_DISPLAY:-} || -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    fail "not inside a Hyprland session; cannot launch"
  else
    launch_and_check "${desktops[0]}"
  fi
elif (( launch )); then
  echo "== Command line"
  for f in "${files[@]}"; do
    [[ $f == /usr/bin/* && -x $f ]] || continue
    if timeout 10 "$f" --version &>"$workdir/cli.log" || timeout 10 "$f" --help &>"$workdir/cli.log"; then
      ok "$f runs ($(head -n 1 "$workdir/cli.log"))"
    else
      fail "$f --version/--help failed: $(head -n 3 "$workdir/cli.log")"
    fi
  done
fi

echo "== $failures failure(s), $skipped check(s) skipped"
if (( failures )); then exit 1; fi
if (( skipped )); then exit 3; fi
