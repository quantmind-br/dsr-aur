# Desktop integration (Hyprland + DankMaterialShell + NVIDIA)

## Desktop entry

Name the file after the app_id: `<app_id>.desktop` (e.g. `org.localsend.localsend_app.desktop`). DankMaterialShell matches windows by desktop ID as well as by `StartupWMClass`. Keep `<name>.desktop` only when the class is generic (`electron`, `java`, `python3`) or unknown until the first launch; `verify-install.sh` reports the class to rename to.

When upstream ships a desktop file (repo, `.deb`, AppImage root), install it and edit it in place with `sed` on `Exec`, `Icon`, `TryExec`, `X-AppImage-*` and `StartupWMClass`. Never regenerate it; that would lose `MimeType`, `Actions`, `Keywords` and translated names. AppImages name their desktop file after the app_id. Otherwise ship one beside the PKGBUILD:

```ini
[Desktop Entry]
Type=Application
Name=Foo
GenericName=File Sharing
Comment=One line from the upstream description
Exec=foo %U
Icon=foo
Terminal=false
Categories=Network;FileTransfer;
Keywords=share;transfer;
StartupWMClass=foo
StartupNotify=true
```

- `Exec` calls the `/usr/bin` wrapper by name. Field codes: `%U` for URLs, `%F` for files, none otherwise.
- `Icon` is a theme name equal to the installed icon file name, without extension or path.
- `StartupWMClass` must equal the Wayland `app_id`; DankMaterialShell uses it to match windows to the entry. Get it from the running app: `hyprctl clients -j | jq -r '.[] | "\(.class)\t\(.title)"'`. Electron uses `desktopName` (minus `.desktop`) or `name` from `package.json`. GTK, Flutter and Qt apps use their application ID, often reverse-DNS (Flutter: `APPLICATION_ID` in `linux/CMakeLists.txt`, e.g. `org.localsend.localsend_app`).
- One main category from: AudioVideo, Audio, Video, Development, Education, Game, Graphics, Network, Office, Science, Settings, System, Utility.
- Remove `TryExec`, `X-AppImage-*` and absolute `Exec` paths copied from upstream files.
- Add `MimeType=` when the app opens files or handles a URL scheme (`x-scheme-handler/foo;`).
- Validate: `desktop-file-validate foo.desktop`.
- TUI apps get an entry only when the user asks; use `Terminal=true`.

pacman hooks refresh the desktop database and icon cache. If DankMaterialShell does not list the app after install, run `dms restart`.

## Icon

Install under the hicolor theme with the icon name used in `Icon=`:

```bash
install -Dm644 icon.svg "$pkgdir/usr/share/icons/hicolor/scalable/apps/$_name.svg"
install -Dm644 icon-256.png "$pkgdir/usr/share/icons/hicolor/256x256/apps/$_name.png"
```

Find them with `scripts/find-icons.py <extracted dir | app.asar> --name <name>`. It drops toolbar, tray, theme-variant and hashed web assets, prefers `icon`/`logo`/app-named files in icon directories, maps each size up to a standard hicolor size (16 to 512, `scalable` for SVG) and prints the install lines. Electron apps often keep their only icon inside `resources/app.asar`: `--extract pkgs/<pkgname>` copies it beside the PKGBUILD (where `source=` looks for local files) and prints the matching `source+=()` and install lines.

- Prefer SVG; otherwise every PNG size upstream provides, each in its matching `NxN` directory.
- PNGs must be square and the directory must match the real size. Anything above 512 goes to `512x512` after `magick icon.png -resize 512x512` (`makedepends+=('imagemagick')`), or commit the resized file.
- Upstream icons live in the repo (`assets/`, `resources/`, `build/icons/`, `src-tauri/icons/`, `linux/`), inside the AppImage (`squashfs-root/usr/share/icons`, `.DirIcon`), the `.deb`, or `app.asar`.

## Launcher wrapper

GUI apps that live in `/opt/<name>` or need environment fixes get `/usr/bin/<name>`:

```bash
#!/bin/bash
# Launch Foo with Wayland/NVIDIA defaults; extra flags from ~/.config/foo-flags.conf,
# one argument per line (--user-data-dir=/home/me/My Profile stays one argument).
flags_file="${XDG_CONFIG_HOME:-$HOME/.config}/foo-flags.conf"
user_flags=()
if [[ -r $flags_file ]]; then
  mapfile -t user_flags < <(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$flags_file")
fi
exec /opt/foo/foo --ozone-platform-hint=auto --enable-wayland-ime "${user_flags[@]}" "$@"
```

Add only the defaults that the toolkit table calls for. Always `exec`, so the window PID is the launched PID.

## Toolkit defaults

| Toolkit | Dependencies | Wrapper defaults |
|---|---|---|
| Electron / Chromium | `gtk3 nss alsa-lib libsecret` (check with namcap) | `--ozone-platform-hint=auto --enable-wayland-ime` |
| WebKitGTK (Tauri, GTK web views) | `webkit2gtk-4.1` or `webkitgtk-6.0` | `export WEBKIT_DISABLE_DMABUF_RENDERER=1` (Tauri: in `Exec`, see its template) |
| Qt 6 / Qt 5 | `qt6-base qt6-wayland` / `qt5-base qt5-wayland` | none |
| GTK 3 / GTK 4 | `gtk3` / `gtk4` | none |
| Java (Swing/AWT) | `java-runtime` | `export _JAVA_AWT_WM_NONREPARENTING=1` |
| SDL 2/3 | `sdl2` / `sdl3` | `export SDL_VIDEODRIVER=wayland,x11` |
| Flutter | `gtk3` | none |
| Vulkan / OpenGL | `vulkan-icd-loader` / `libglvnd` | none |

Never depend on `nvidia-utils` or a specific driver; depend on the generic loaders. CUDA apps depend on `cuda` (or `opencl-nvidia` for OpenCL) and must build for `sm_86` (`CMAKE_CUDA_ARCHITECTURES=86`, `TORCH_CUDA_ARCH_LIST=8.6`). A CUDA source build is slow under QEMU; prefer the `-bin` variant.

## Symptoms and fixes

| Symptom (verify-install output or screenshot) | Fix |
|---|---|
| White, blank or black window in a WebKitGTK app | `export WEBKIT_DISABLE_DMABUF_RENDERER=1` |
| Electron window black, flickering, or `GPU process exited unexpectedly` | add `--disable-gpu-compositing`; last resort `--disable-gpu` |
| Electron opens under XWayland (blurry with scaling) | `--ozone-platform-hint=auto` (or `--ozone-platform=wayland`) |
| GTK 4 rendering glitches | `export GSK_RENDERER=ngl` |
| `Could not load the Qt platform plugin "wayland"` | add `qt6-wayland`; for bundled Qt without the plugin, `export QT_QPA_PLATFORM=xcb` |
| Java window grey or empty | `export _JAVA_AWT_WM_NONREPARENTING=1` |
| `error while loading shared libraries` | add the package that owns the soname (`pacman -F <soname>`) |
| `Illegal instruction` | the build used AVX-512 or `-march=native`; remove the override |
| Window class differs from `StartupWMClass` | set `StartupWMClass` to the reported class |
| Process exits without a window | the app is single-instance and already running (close it), or it crashed: read the log |
| `required file not found` running a binary from an AppImage | its ELF interpreter is relative (`readelf -l <bin>`, appimage-builder with `AppRun.env`): exec `/opt/<name>/AppRun` from the wrapper |
| verify-install skips the screenshot | the session is locked (`dms ipc call lock isLocked`); rerun after unlocking |
| App missing from the DMS launcher | check `NoDisplay`/`Hidden` keys, validate the entry, `dms restart` |
