# dsr-aur

Personal pacman repository built from AUR and local PKGBUILDs, served at
<https://aur.quantforge.com.br>.

## Using the repository

Trust the signing key:

```bash
curl -fsSL https://aur.quantforge.com.br/dsr-aur.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key 527847CE99A97C4EEB1CA5394250FF48D2374AED
```

Add to `/etc/pacman.conf`:

```ini
[dsr-aur]
SigLevel = Required
Server = https://aur.quantforge.com.br/$arch
```

Then `sudo pacman -Sy <package>`.

## Adding packages

- **From the AUR:** add the package name to `aur.txt`. List AUR dependencies
  before the packages that need them. Pin a reviewed revision with
  `name@<commit>`.
- **Local PKGBUILD:** create `pkgs/<name>/PKGBUILD` with its source files.
  Add `pkgs/<name>/.nvchecker.toml` (section named after the package) to
  follow upstream releases: each cycle the builder asks
  [nvchecker](https://github.com/lilydjwg/nvchecker) for the latest version
  and, when newer, rewrites `pkgver`, resets `pkgrel=1` and runs
  `updpkgsums` before building. The version must be a valid `pkgver` (no
  `-`), so strip prefixes in the nvchecker config:

  ```toml
  [dsr-foo-bin]
  source = "github"
  github = "owner/foo"
  use_latest_release = true
  prefix = "v"
  ```

  VCS packages (`pkgver()`) update without it.

  Before building, every GitHub release asset in `source=` is compared with
  the sha256 digest the GitHub API publishes for it; a mismatch fails the
  package and drops the cached file.

Push to `main`. Dokploy redeploys the stack, and the builder builds on startup.

## How it works

`docker-compose.yml` runs two services, deployed by Dokploy:

- **builder:** Arch Linux container running `build-repo loop`. Every
  `BUILD_INTERVAL` it updates the system, then builds each package whose
  files are missing from the repository. VCS packages run `pkgver()` first to
  learn their real version. Packages are signed and added with `repo-add`.
  Packages that disappear from `aur.txt` and `pkgs/` are removed, unless some
  build failed in that cycle.
- **web:** Caddy serving the `repo` volume read-only. Traefik (Dokploy)
  terminates TLS for `aur.quantforge.com.br`.

The VPS is ARM64, so the builder runs as `linux/amd64` through QEMU user-mode
emulation. Repackaging `-bin` packages is quick; compiling is several times
slower than native. Ubuntu 24.04's QEMU 8.2 crashes `grep` under current
glibc, so the host registers QEMU 10.2.3 (static binary taken from
`tonistiigi/binfmt`) at `/usr/local/lib/qemu-binfmt/qemu-x86_64` through
`/etc/binfmt.d/qemu-x86_64.conf`. The builder aborts a cycle when core tools
crash.

Compiled packages target the Zen 5 desktop with `-march=x86-64-v3
-mtune=znver5` (Rust `target-cpu=x86-64-v3`, `GOAMD64=v3`), set in
`builder/makepkg.conf`. Do not raise it to `x86-64-v4`: QEMU cannot execute
AVX-512, and builds run their own binaries.

PKGBUILD code runs as the unprivileged `builder` user without sudo. Root
installs build dependencies and holds the signing key. AUR PKGBUILDs are still
third-party code: review them before adding, and pin a commit.

## Operations

Build now instead of waiting for the next cycle (on the VPS):

```bash
docker exec compose-quantify-neural-alarm-8a391p-builder-1 build-repo once
```

Rebuild everything with `docker exec -e FORCE=1 <builder> build-repo once`.
Prefer bumping `pkgrel`:
Cloudflare caches package files by name, so rebuilding the same version can
serve a stale file next to a new signature.

The signing key is generated on the first run and kept in the `signing`
volume. Back it up: losing it means a new key that every client must trust
again.

Settings (Dokploy environment):

| Variable | Default | Meaning |
|---|---|---|
| `BUILD_INTERVAL` | `6h` | Time between build cycles (`sleep` syntax) |
| `BUILDER_CPUS` | `1.5` | CPU limit for the builder |
| `BUILDER_MEMORY` | `6g` | Memory limit for the builder |
| `PACKAGER` | `quantmind-br <dsrodrigues20@gmail.com>` | Packager recorded in built packages |
| `GITHUB_TOKEN` | unset | Token for nvchecker's GitHub queries (lifts the 60 requests/hour limit); never exposed to builds |
