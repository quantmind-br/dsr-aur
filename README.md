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

Then `sudo pacman -Syu <package>` (never `-Sy` alone: that is a partial upgrade).

## Adding packages

- **From the AUR:** add the package name to `aur.txt`. Pin a reviewed revision
  with `name@<commit>`.
- **Local PKGBUILD:** create `pkgs/<name>/PKGBUILD` with its source files. Add
  `pkgs/<name>/.nvchecker.toml` (section named after the package) to follow
  upstream releases. The version must be a valid `pkgver` (no `-`), so strip
  prefixes in the nvchecker config:

  ```toml
  [dsr-foo-bin]
  source = "github"
  github = "owner/foo"
  use_latest_release = true
  prefix = "v"
  ```

  VCS packages (`pkgver()`) update without it.

Packages may depend on each other in any order: a package whose dependencies
are missing is retried after the others in the same cycle.

Push to `main`. Dokploy redeploys the stack, and the builder builds on startup.

## How it works

`docker-compose.yml` runs three services, deployed by Dokploy from this
repository. The builder and the publisher share one image and exchange work
through the `exchange` volume.

- **builder** (`dsr-build loop`): every `BUILD_INTERVAL` it updates the
  system and, for each source, copies the PKGBUILD into a fresh directory,
  applies the upstream version and builds it when the database does not hold
  that version yet. It writes one batch (packages plus a manifest) per cycle.
  It runs third-party code, so it has no signing key, no token, and only
  read-only access to the published repository.
- **publisher** (`dsr-publish loop`): every minute it validates each package
  of a pending batch, signs it, publishes it, runs `repo-add
  --prevent-downgrade`, checks the database signatures, prunes packages that
  left the sources and writes `status.json`. Hourly it resolves upstream
  versions with [nvchecker](https://github.com/lilydjwg/nvchecker) for every
  `.nvchecker.toml` and writes them to the exchange volume. It never runs
  PKGBUILD code and alone holds the signing key and `GITHUB_TOKEN`.
- **web**: Caddy serving the `repo` volume read-only. Traefik (Dokploy)
  terminates TLS for `aur.quantforge.com.br`.

Builder safeguards:

- Each package builds as its own unprivileged user (`dsrb<uid>`, UID derived
  from the package name), without sudo. Its sources, download cache, ccache
  and home are private (`700`), so one PKGBUILD cannot alter another package.
  Root installs build dependencies, after checking that every `.SRCINFO`
  entry looks like a dependency, and passes them after `--`.
- Root never writes into directories a build user can modify. It copies
  outputs only when they are regular files at the expected path. It kills
  the build user's processes before each root step and after each package.
- The version never drops below the published one. When the upstream check
  fails, the published version is kept, and `pkgrel` comes from git.
- GitHub release assets in `source=` must match the sha256 digest the GitHub
  API publishes. A mismatch, or an API failure, fails the package for this
  cycle. Assets older than GitHub's digests rely on the PKGBUILD checksums.
- A cycle aborts when core tools crash (QEMU) or the disk has less than
  `MIN_FREE_GB` free.

Publisher safeguards:

- Every package is checked for a regular file whose `.PKGINFO` matches its
  name. Published file names are immutable: rebuilding the same version is
  rejected, so bump `pkgrel` instead. Cloudflare and clients cache packages by
  name.
- Pruning happens only when the whole cycle succeeded. It also refuses to
  empty the repository unless `ALLOW_EMPTY_PRUNE=1`.
- Files the database no longer lists are deleted after `DELETE_GRACE_HOURS`,
  so clients holding a slightly older database can still download them.

`https://aur.quantforge.com.br/status.json` shows the last cycle: what was
built, what failed, the package count and the signing key.

The VPS is ARM64, so both services run as `linux/amd64` through QEMU user-mode
emulation. Repackaging `-bin` packages is quick; compiling is several times
slower than native. Ubuntu 24.04's QEMU 8.2 crashes `grep` under current
glibc, so the host registers QEMU 10.2.3 at
`/usr/local/lib/qemu-binfmt/qemu-x86_64` through
`/etc/binfmt.d/qemu-x86_64.conf`. The static binary comes from
`tonistiigi/binfmt@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0`.

Compiled packages target the Zen 5 desktop with `-march=x86-64-v3
-mtune=znver5` (Rust `target-cpu=x86-64-v3`, `GOAMD64=v3`), set in
`builder/makepkg.conf`. Do not raise it to `x86-64-v4`: QEMU cannot execute
AVX-512, and builds run their own binaries.

Limits:

- AUR PKGBUILDs, and the dependencies upstream build systems download, are
  third-party code. Root installs packages from this repository as build
  dependencies, so a malicious package can take over the builder container,
  and the container lives across cycles. The key and the token are out of
  its reach, but it could still tamper with later builds. Review AUR
  additions, pin commits and require lockfiles.
- A soname bump in Arch does not trigger rebuilds: bump `pkgrel` of the
  affected packages.

## Operations

Build or publish now instead of waiting (on the VPS):

```bash
docker exec compose-quantify-neural-alarm-8a391p-builder-1 dsr-build once
docker exec compose-quantify-neural-alarm-8a391p-publisher-1 dsr-publish once
```

The signing key is generated on the first run and kept in the `signing`
volume (publisher only). Back it up: losing it means a new key that every
client must trust again.

Settings (Dokploy environment):

| Variable | Default | Meaning |
|---|---|---|
| `BUILD_INTERVAL` | `6h` | Time between build cycles (`sleep` syntax) |
| `BUILD_TIMEOUT` | `8h` | Limit for a single makepkg run |
| `BUILDER_CPUS` | `1.5` | CPU limit for the builder |
| `BUILDER_MEMORY` | `6g` | Memory limit for the builder |
| `PACKAGER` | `quantmind-br <dsrodrigues20@gmail.com>` | Packager recorded in built packages |
| `GITHUB_TOKEN` | unset | Publisher only: token for nvchecker (lifts the 60 requests/hour limit; required by `include_prereleases` with `use_latest_release`) |
| `DELETE_GRACE_HOURS` | `24` | How long unreferenced package files stay downloadable |
