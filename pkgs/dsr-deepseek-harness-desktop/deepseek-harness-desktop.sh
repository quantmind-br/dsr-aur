#!/bin/bash
# Launch DeepSeek Harness with Wayland defaults; extra flags from
# ~/.config/deepseek-harness-desktop-flags.conf, one argument per line.
# Chromium's sandbox uses unprivileged user namespaces, which Arch enables by default;
# add --no-sandbox to the flags file only if the kernel reports them as unavailable.
flags_file="${XDG_CONFIG_HOME:-$HOME/.config}/deepseek-harness-desktop-flags.conf"
user_flags=()
if [[ -r $flags_file ]]; then
  mapfile -t user_flags < <(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$flags_file")
fi
exec /usr/lib/deepseek-harness-desktop/deepseek-harness --ozone-platform-hint=auto --enable-wayland-ime "${user_flags[@]}" "$@"
