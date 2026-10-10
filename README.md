# dsr-aur

Personal pacman repository built from AUR and local PKGBUILDs, served at
<https://aur.quantforge.com.br>.

## Using the repository

Trust the signing key:

```bash
curl -fsSL https://aur.quantforge.com.br/dsr-aur.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key <FINGERPRINT>
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
