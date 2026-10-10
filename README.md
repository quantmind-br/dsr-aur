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

- **From the AUR:** add `name@<commit>` to `aur.txt` after reviewing the
  PKGBUILD at that commit. Unpinned entries are refused
  (`ALLOW_UNPINNED_AUR=1` overrides); bump the pin only after reading the diff.
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
repository. The builder and the publisher share one image. The builder hands
batches over through the `exchange` volume; the publisher copies each batch
out without following symlinks before reading it. The publisher answers
through the `control` volume, which the builder mounts read-only.

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
  `.nvchecker.toml` and writes them to the `control` volume. It never runs
  PKGBUILD code and alone holds the signing key and `GITHUB_TOKEN`.
- **web**: Caddy serving the `repo` volume read-only. Traefik (Dokploy)
  terminates TLS for `aur.quantforge.com.br`.

Builder safeguards:

- Each package builds as its own unprivileged user (`dsrb<uid>`, UID
  allocated once per package and kept in a root-only map on the cache
  volume), without sudo. Its sources, download cache, ccache
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
- A package whose library dependencies broke is rebuilt with a pkgrel just
  above the published one (`1` → `1.1` → `1.2`; a later `pkgrel=2` in git
  still wins). Breaks are found two ways: every cycle, `pacman -Sp` reports
  `lib:` dependencies (recorded by makepkg's autodeps) that nothing provides
  any more; every `ABI_CHECK_HOURS`, the sonames each published package needs
  (read with `readelf`) are looked up in the repositories' files databases,
  which covers libraries whose packages do not declare `lib:` yet. A
  notification lists what was rebuilt.
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
- With `NOTIFY_URL` (an [ntfy](https://ntfy.sh) topic URL) it notifies build
  failures, rejected packages and publishing errors once per distinct
  problem (again after a day), and when they clear. A dead man's switch alerts
  when the builder's heartbeat is older than `STALE_HOURS`.

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
  its reach, but it could still tamper with later builds. Review pinned
  commits and require lockfiles.
- Libraries loaded with `dlopen` (plugins) are not tracked, and a rebuild
  can lag one build interval behind an Arch library update.

## Operations

Build or publish now instead of waiting (on the VPS):

```bash
docker exec compose-quantify-neural-alarm-8a391p-builder-1 dsr-build once
docker exec compose-quantify-neural-alarm-8a391p-publisher-1 dsr-publish once
```

The signing key is generated on the first run and kept in the `signing`
volume (publisher only). An encrypted backup lives outside the VPS; see
[Signing key](#signing-key).

Settings (Dokploy environment):

| Variable | Default | Meaning |
|---|---|---|
| `BUILD_INTERVAL` | `6h` | Time between build cycles (`sleep` syntax) |
| `BUILD_TIMEOUT` | `8h` | Limit for a single makepkg run |
| `STEP_TIMEOUT` | `1h` | Limit for every other build step (`--printsrcinfo`, `updpkgsums`, source download, pacman) |
| `MIN_FREE_GB` | `5` | Builder: skip packages while the cache or work disk has less free space. Publisher: hold batches while the repository volume has less |
| `ABI_CHECK_HOURS` | `24` | How often published packages are checked against the files databases for sonames no repository ships |
| `HOME_CACHE_MAX_GB` | `5` | Drop a package's tool caches (npm, cargo, go) beyond this size |
| `BUILDER_CPUS` | `1.5` | CPU limit for the builder |
| `BUILDER_MEMORY` | `6g` | Memory limit for the builder |
| `PACKAGER` | `quantmind-br <dsrodrigues20@gmail.com>` | Packager recorded in built packages |
| `SIGN_KEY_FPR` | unset | Publisher: fingerprint of the active signing key (see [Signing key](#signing-key)) |
| `GITHUB_TOKEN` | unset | Publisher only: token for nvchecker (lifts the 60 requests/hour limit; required by `include_prereleases` with `use_latest_release`) |
| `DELETE_GRACE_HOURS` | `24` | How long unreferenced package files stay downloadable |
| `NOTIFY_URL` | unset | Publisher: ntfy topic URL for alerts |
| `STALE_HOURS` | `12` | Publisher: alert when the builder's heartbeat is older than this |
| `ALLOW_UNPINNED_AUR` | `0` | Builder: accept `aur.txt` entries without `@commit` |

## Signing key

The publisher signs with `SIGN_KEY_FPR` (set it in Dokploy). If that key is
missing from the `signing` volume, publishing stops and an alert goes out;
it never falls back to a new key that clients would reject. Without
`SIGN_KEY_FPR`, a key is generated on the first run. `dsr-aur.asc` carries
every public key in the keyring.

Names used below: `P=compose-quantify-neural-alarm-8a391p` (Dokploy project)
and the image `dsr-aur-builder:local` on the VPS.

**Back up** the private key, encrypted to an SSH key you keep (age accepts
`ssh-ed25519` recipients):

```bash
ssh quantforge "docker exec $P-publisher-1 env GNUPGHOME=/var/lib/dsr-aur/gnupg gpg --batch --armor --export-secret-keys" |
  docker run --rm -i -v ~/.ssh/id_ed25519.pub:/k.pub:ro alpine sh -c 'apk add -q age && age -R /k.pub' \
  >dsr-aur-signing-key.asc.age
```

**Restore** into an empty or damaged `signing` volume, with the publisher
stopped so it cannot act on a half-restored keyring, and check that the
fingerprint matches `SIGN_KEY_FPR`:

```bash
ssh quantforge "docker stop $P-publisher-1"
docker run --rm -i -v ~/.ssh/id_ed25519:/k:ro alpine sh -c 'apk add -q age && age -d -i /k' <dsr-aur-signing-key.asc.age |
  ssh quantforge "docker run --rm -i -v ${P}_signing:/var/lib/dsr-aur --entrypoint sh dsr-aur-builder:local -c \
    'install -d -m 700 /var/lib/dsr-aur/gnupg && export GNUPGHOME=/var/lib/dsr-aur/gnupg &&
     gpg --batch --import && gpg --list-secret-keys --with-colons | grep ^fpr'"
ssh quantforge "docker start $P-publisher-1"
```

**Rotate** (key lost or exposed):

1. Generate the new key next to the old one:
   `docker exec $P-publisher-1 env GNUPGHOME=/var/lib/dsr-aur/gnupg gpg --batch --yes --pinentry-mode loopback --passphrase '' --quick-gen-key "dsr-aur repository signing key" ed25519 sign never`
   (`--yes` because a key with that user ID already exists).
   Within a minute `dsr-aur.asc` carries both public keys.
2. On every client: `curl -fsSL https://aur.quantforge.com.br/dsr-aur.asc | sudo pacman-key --add -`
   and `sudo pacman-key --lsign-key <new fingerprint>`.
3. Set `SIGN_KEY_FPR` to the new fingerprint in Dokploy, redeploy, then
   re-sign what is already published: `docker exec $P-publisher-1 dsr-publish resign`.
   Signatures are not cached by Cloudflare, so clients see them at once.
4. Back up the new key.
5. Once every client trusts the new key, delete the old one from the keyring
   (`gpg --batch --yes --delete-secret-and-public-key <old fingerprint>` with
   the same `GNUPGHOME`). If it was exposed, clients run
   `sudo pacman-key --delete <old fingerprint>`.
