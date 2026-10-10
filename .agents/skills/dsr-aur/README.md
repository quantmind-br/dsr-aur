# dsr-aur skill

Agent skill that turns a GitHub repository into `dsr-` packages for the
personal pacman repository served at <https://aur.quantforge.com.br>
(source: `~/dev/dsr-aur`, GitHub `quantmind-br/dsr-aur`). Installed by
symlink at `~/.agents/skills/dsr-aur`.

## Layout

- `SKILL.md`: workflow loaded by the agent.
- `references/pkgbuild-templates.md`: PKGBUILD and `.nvchecker.toml` templates per asset type and build system, Debian to Arch dependency names.
- `references/desktop-integration.md`: desktop entry, icons, wrapper, toolkit defaults and NVIDIA/Wayland fixes.
- `scripts/inspect-repo.sh`: GitHub metadata, release assets (through `pick-asset.py`), build files, desktop assets, existing packages.
- `scripts/pick-asset.py`: release asset ranking with exclusion reasons, `source=` template, `.nvchecker.toml` suggestion.
- `scripts/find-executable.py`: ranks ELF executables in an extracted tree to choose the wrapper target.
- `scripts/find-icons.py`: ranks icons in a tree or `app.asar`, maps them to hicolor sizes, can extract them.
- `scripts/test-build.sh`: native `dsr-publish versions` then `dsr-build once` inside the repository's image; packages from the handed-over batch are copied to `./dsr-test-out`.
- `scripts/verify-install.sh`: post-install checks, real launch through Hyprland, screenshot via `grim`.

## Design notes

- Packages are compiled with `-march=x86-64-v3 -mtune=znver5`, not `znver5`/`x86-64-v4`: the server builder is x86_64 under QEMU on ARM64, which executes AVX2/FMA/BMI2 but raises SIGILL on AVX-512, and builds run their own binaries (tests, build scripts).
- The repository runs a builder (third-party code, no key, no token) and a publisher (validates, signs, publishes, resolves upstream versions with nvchecker). PKGBUILDs in git keep their original version; the builder raises its working copy to the publisher's upstream version, never below the published one, keeps `pkgrel` from git, and checks GitHub release assets against the API digests. Published file names are immutable.
- nvchecker's `include_regex` must match the whole tag. Monorepo suggestions use a stable-only regex because some projects (tauri) publish alphas without the prerelease flag.
- AppImages are unpacked with `unsquashfs -o <offset>` computed from the ELF section header table, so nothing upstream runs at build time. appimage-builder images use a relative ELF interpreter and must be launched through `AppRun`.
- The test build runs the same image as the server, so dependency resolution (root installs from `.SRCINFO`, no sudo for makepkg), flags and the nvchecker bump are exercised before publishing.
- `verify-install.sh` launches the `Exec` line in its own session (`setsid`), matches the Hyprland client by PID within that session (wrappers and AppImage runtimes fork), and kills the session afterwards. Unresolved libraries fail only for entry points; bundled helpers are reported. It skips the screenshot while DankMaterialShell reports the session locked.
- Ideas ported from `~/dev/upkg` (logic only, no dependency): asset exclusion and scoring, executable scoring, desktop file named after the app_id and edited in place, icon size normalization and asar extraction, monorepo/prerelease handling for version tracking, release digest verification, Debian dependency mapping.

## Changelog

- 2026-10-10: initial version.
- 2026-10-10: asset, executable and icon pickers; app_id desktop names; unsquashfs AppImage extraction; nvchecker monorepo/prerelease rules; release digest checks; lock-aware screenshots.
- 2026-10-10: fixes from the Codex (gpt-6-astra) review: builder/publisher split, `-git` pkgver fallback, versioned `provides`, prerelease nvchecker config without token, Tauri via deb bundle, array-based wrapper flags, inspect-repo no-match handling, test-build export checks, verify-install cleanup/Path/Terminal/grim handling, square-only icons with extract-aware install lines, bare binaries with versioned names.
- 2026-10-10: second Codex review: test-build resolves upstream versions first, `-git` provides versioned with tags, epoch in provides, verify-install exit 3 for inconclusive runs, icon extraction into the PKGBUILD directory.
- 2026-10-10: third Codex review: test-build fails when upstream version resolution fails (and forwards GITHUB_TOKEN to the resolver), epoch in the provides rule.
- 2026-10-10: note the builder's automatic ABI rebuilds (fractional pkgrel).
