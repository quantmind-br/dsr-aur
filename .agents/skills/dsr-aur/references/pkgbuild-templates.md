# PKGBUILD templates

Replace `foo`, `Foo`, `owner` and versions. Keep `_name` as the upstream name used for installed files.

## Common rules

- Name downloads `"$_name-$pkgver.<ext>::<url>"` so a version-less asset name never collides with an older download in the cache.
- Use `$pkgver` in every versioned URL; the builder rewrites only `pkgver`. If the tag is not `v$pkgver`, derive it in a variable (`_tag="release-$pkgver"`).
- `pkgver` cannot contain `-`. For tags like `1.0.0-beta.1`, map `-` to `_` in nvchecker and use `${pkgver//_/-}` in URLs.
- Find runtime dependencies from `namcap` output and `ldd` on the binaries; list sonames' owning packages (`pacman -F libfoo.so.1`).
- Install the license when it is not a common one in `/usr/share/licenses/common`: `install -Dm644 LICENSE -t "$pkgdir/usr/share/licenses/$pkgname"`.
- Electron, AppImage and other prebuilt trees: `options=('!strip')`. namcap's `ELF files outside of a valid path ('opt/')` is expected for them.
- Upstream CI often leaves its build directory as RUNPATH (namcap `Insecure RUNPATH '/home/runner/...'`), which also hides bundled libraries from `ldd`. Rewrite it in `package()`: `patchelf --set-rpath '$ORIGIN' <files>` with `makedepends+=('patchelf')`.
- `arch=('x86_64')` for native code, `arch=('any')` only for pure scripts.

## .nvchecker.toml

`scripts/pick-asset.py` prints a suggested section; rename `<pkgname>`. The section name must equal `pkgname`. `include_regex` must match the whole tag.

```toml
# Latest GitHub release (prereleases excluded), tag "v1.2.3"
[dsr-foo]
source = "github"
github = "owner/foo"
use_latest_release = true
prefix = "v"
```

```toml
# Only tags, no releases
[dsr-foo]
source = "github"
github = "owner/foo"
use_max_tag = true
prefix = "v"
include_regex = 'v\d+(\.\d+)*'
```

```toml
# Monorepo: several components release from one repo (tags "desktop-v1.2.3", "cli-v0.4.0").
# Stable-only regex: some projects publish alphas without marking them prerelease.
[dsr-foo]
source = "github"
github = "owner/foo"
use_max_release = true
include_regex = 'desktop\-v\d+(\.\d+)*'
prefix = "desktop-v"
```

```toml
# Only prereleases exist (/releases/latest answers 404). use_latest_release with
# include_prereleases needs a GitHub token (GraphQL); use_max_release does not.
[dsr-foo]
source = "github"
github = "owner/foo"
use_max_release = true
include_prereleases = true
prefix = "v"
```

```toml
# Tags with "-" (1.0.0-beta.1 becomes pkgver 1.0.0_beta.1)
[dsr-foo-bin]
source = "github"
github = "owner/foo"
use_latest_release = true
prefix = "v"
from_pattern = '-'
to_pattern = '_'
```

Check it locally: `nvchecker -c .nvchecker.toml` (package `nvchecker`).

## Header shared by all variants

```bash
# Maintainer: quantmind-br <dsrodrigues20@gmail.com>
pkgname=dsr-foo
_name=foo
pkgver=1.2.3
pkgrel=1
pkgdesc='One line from the upstream description'
arch=('x86_64')
url='https://github.com/owner/foo'
license=('MIT')
provides=("$_name=${epoch:+$epoch:}$pkgver")
conflicts=("$_name" "$_name-bin" "$_name-git" 'dsr-foo-bin')
```

The versioned `provides` satisfies dependencies such as `foo>=1.2`.

## Binary variants (`dsr-foo-bin`)

Pick the asset with `scripts/pick-asset.py <repo>`. It drops checksums, signatures, debug and source archives, other OSes (including `*.app.tar.gz`, which is macOS) and other architectures, then ranks: `.pkg.tar.zst` > tarball > `.deb` > `.AppImage` > `.rpm` > `.zip`, glibc over musl. It prints why each asset was excluded, the `source=` line template and the asset's sha256 digest. When it reports no clear winner (GUI and CLI tarballs, for example), choose by content.

For trees installed under `/opt/$_name`, find the binary the wrapper execs with `scripts/find-executable.py <extracted dir> --name foo`. It ranks ELF files by depth, name and size, and ranks helpers such as `chrome-sandbox`, crash handlers and updaters last.

### Tarball

```bash
source=("$_name-$pkgver.tar.gz::$url/releases/download/v$pkgver/foo-v$pkgver-x86_64-unknown-linux-gnu.tar.gz")
sha256sums=('...')

package() {
  cd "foo-v$pkgver-x86_64-unknown-linux-gnu"
  install -Dm755 "$_name" -t "$pkgdir/usr/bin"
  install -Dm644 LICENSE -t "$pkgdir/usr/share/licenses/$pkgname"
}
```

A tree with libraries or resources goes to `/opt/$_name`, with a wrapper in `/usr/bin` (see desktop integration).

### Debian package

makepkg unpacks the `.deb`, leaving `data.tar.*` in `$srcdir`.

```bash
options=('!strip')
source=("$_name-$pkgver.deb::$url/releases/download/v$pkgver/foo_${pkgver}_amd64.deb"
        "$_name.sh")
sha256sums=('...' '...')

package() {
  bsdtar -xf data.tar.* -C "$pkgdir"
  rm -rf "$pkgdir/usr/share/doc" "$pkgdir/usr/share/lintian"
  install -Dm755 "$_name.sh" "$pkgdir/usr/bin/$_name"   # replaces upstream launcher or symlink
  # Edit the upstream desktop entry in place (keeps MimeType, Actions, translations):
  sed -i -e "s|^Exec=[^ ]*|Exec=$_name|" -e "s|^Icon=.*|Icon=$_name|" \
    "$pkgdir/usr/share/applications/"*.desktop
}
```

`s|^Exec=[^ ]*|...|` swaps only the command and keeps its arguments and field codes. Keep upstream's desktop file name when it already equals the app_id (see desktop integration). Rename icons to `$_name` and add `StartupWMClass` when missing.

`.deb` dependency names map to Arch packages; start from this table and confirm with namcap:

| Debian | Arch |
|---|---|
| `libgtk-3-0` | `gtk3` |
| `libnss3` | `nss` |
| `libasound2` | `alsa-lib` |
| `libgbm1` | `mesa` |
| `libxss1` | `libxss` |
| `libxtst6` | `libxtst` |
| `libnotify4` | `libnotify` |
| `libsecret-1-0` | `libsecret` |
| `libuuid1` | `util-linux-libs` |
| `libcups2` | `libcups` |
| `libdrm2` | `libdrm` |
| `libatspi2.0-0` | `at-spi2-core` |
| `libglib2.0-0` | `glib2` |
| `libssl3` | `openssl` |
| `zlib1g` | `zlib` |
| `libwebkit2gtk-4.1-0` | `webkit2gtk-4.1` |
| `libayatana-appindicator3-1` | `libayatana-appindicator` |
| `xdg-utils` | `xdg-utils` |
| `python3` | `python` |

### AppImage

Unpack the squashfs image that follows the ELF runtime. Nothing upstream runs at build time and no FUSE is needed.

```bash
makedepends=('squashfs-tools')
options=('!strip')
noextract=("$_name-$pkgver.AppImage")
source=("$_name-$pkgver.AppImage::$url/releases/download/v$pkgver/Foo-$pkgver-linux-x86_64.AppImage"
        "$_name.sh")
sha256sums=('...' '...')

prepare() {
  local appimage=$_name-$pkgver.AppImage offset
  # The squashfs starts where the ELF runtime ends: after its section header table.
  offset=$(LC_ALL=C readelf -h "$appimage" | awk '
    /Start of section headers/ { start = $5 } /Size of section headers/ { size = $5 }
    /Number of section headers/ { count = $5 } END { print start + size * count }')
  rm -rf squashfs-root
  unsquashfs -q -n -d squashfs-root -o "$offset" "$appimage"
}

package() {
  install -d "$pkgdir/opt/$_name"
  cp -a squashfs-root/. "$pkgdir/opt/$_name/"
  chmod -R u=rwX,go=rX "$pkgdir/opt/$_name"
  install -Dm755 "$_name.sh" "$pkgdir/usr/bin/$_name"
  # The AppImage's desktop file is usually named after the app_id (verify-install confirms):
  # keep the name, fix Exec and Icon, add StartupWMClass when missing.
  local desktop=(squashfs-root/*.desktop) app_id entry
  app_id=$(basename "${desktop[0]}" .desktop)
  entry=$pkgdir/usr/share/applications/$app_id.desktop
  install -Dm644 "${desktop[0]}" "$entry"
  sed -i -e "s|^Exec=[^ ]*|Exec=$_name|" -e "s|^Icon=.*|Icon=$_name|" -e '/^X-AppImage-/d' -e '/^TryExec=/d' "$entry"
  grep -q '^StartupWMClass=' "$entry" || sed -i "/^\[Desktop Entry\]/a StartupWMClass=$app_id" "$entry"
  local icon size
  for icon in squashfs-root/usr/share/icons/hicolor/*/apps/*.{png,svg}; do
    [[ -f $icon ]] || continue
    size=$(basename "$(dirname "$(dirname "$icon")")")
    install -Dm644 "$icon" "$pkgdir/usr/share/icons/hicolor/$size/apps/$_name.${icon##*.}"
  done
}
```

Without hicolor icons inside, `.DirIcon` (a symlink to the top-level icon) names the icon to use. The wrapper execs the real binary inside `/opt/$_name` (`scripts/find-executable.py`, or read `AppRun`). Exec `/opt/$_name/AppRun` instead when the binary's ELF interpreter is relative (`readelf -l <bin> | grep interpreter` shows `lib64/ld-linux-x86-64.so.2`; appimage-builder images, which carry `AppRun.env`) or when `AppRun` sets an environment the app needs.

## Source variants (`dsr-foo`)

GitHub tag archives unpack to `<repo>-<tag without leading v>`.

```bash
source=("$_name-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
```

When the build needs git metadata or submodules, use `source=("$_name::git+$url.git#tag=v$pkgver")`, `makedepends+=('git')`, `sha256sums=('SKIP')` and work in `"$_name"`.

### Rust

```bash
makedepends=('cargo')
depends=('gcc-libs' 'glibc')

prepare() {
  cd "$_name-$pkgver"
  cargo fetch --locked --target "$(rustc -vV | sed -n 's/host: //p')"
}

build() {
  cd "$_name-$pkgver"
  CARGO_TARGET_DIR=target cargo build --frozen --release
}

package() {
  cd "$_name-$pkgver"
  install -Dm755 "target/release/$_name" -t "$pkgdir/usr/bin"
}
```

Without `Cargo.lock`, drop `--locked`/`--frozen`.

### Go

```bash
makedepends=('go')

build() {
  cd "$_name-$pkgver"
  export CGO_CPPFLAGS="$CPPFLAGS" CGO_CFLAGS="$CFLAGS" CGO_CXXFLAGS="$CXXFLAGS" CGO_LDFLAGS="$LDFLAGS"
  export GOFLAGS='-buildmode=pie -trimpath -ldflags=-linkmode=external -mod=readonly -modcacherw'
  go build -o build/ ./cmd/...   # or "." for a single main package
}

package() {
  cd "$_name-$pkgver"
  install -Dm755 "build/$_name" -t "$pkgdir/usr/bin"
}
```

### CMake

```bash
makedepends=('cmake' 'ninja')

build() {
  cmake -B build -S "$_name-$pkgver" -G Ninja \
    -DCMAKE_BUILD_TYPE=None -DCMAKE_INSTALL_PREFIX=/usr -Wno-dev
  cmake --build build
}

package() {
  DESTDIR="$pkgdir" cmake --install build
}
```

CUDA code: add `-DCMAKE_CUDA_ARCHITECTURES=86` (RTX 3090); the builder has no GPU to detect.

### Meson

```bash
makedepends=('meson')

build() {
  arch-meson "$_name-$pkgver" build
  meson compile -C build
}

package() {
  meson install -C build --destdir "$pkgdir"
}
```

### Python

```bash
makedepends=('python-build' 'python-installer' 'python-wheel' 'python-setuptools')  # or python-hatchling, python-poetry-core...
depends=('python')

build() {
  cd "$_name-$pkgver"
  python -m build --wheel --no-isolation
}

package() {
  cd "$_name-$pkgver"
  python -m installer --destdir="$pkgdir" dist/*.whl
}
```

Every runtime import must be a `python-*` dependency from the repos; if one is missing, prefer the `-bin` variant.

### Electron (npm, pnpm or yarn)

```bash
makedepends=('nodejs' 'npm')   # 'pnpm' or 'yarn' when the lockfile says so
depends=('gtk3' 'nss' 'alsa-lib' 'libsecret')
options=('!strip')

build() {
  cd "$_name-$pkgver"
  npm ci
  npm run build --if-present
  npx electron-builder --linux dir --publish never
}

package() {
  cd "$_name-$pkgver"
  install -d "$pkgdir/opt/$_name"
  cp -a dist/linux-unpacked/. "$pkgdir/opt/$_name/"
  install -Dm755 "$srcdir/$_name.sh" "$pkgdir/usr/bin/$_name"
}
```

Follow the upstream CI if it packages differently (electron-forge: `npx electron-forge package`, output under `out/`).

### Tauri

Build the deb bundle and unpack it. It holds the binary, `bundle.resources`, sidecars (`externalBin`), the desktop entry and the icons in their final layout. Tauri finds its resources relative to `/usr/bin` (`/usr/lib/<productName>`), so the binary stays there under its own name and the WebKitGTK fix goes into `Exec`.

```bash
makedepends=('cargo' 'nodejs' 'npm')
depends=('webkit2gtk-4.1' 'gtk3' 'libayatana-appindicator')

build() {
  cd "$_name-$pkgver"
  npm ci
  npm run tauri build -- --bundles deb
}

package() {
  cd "$_name-$pkgver"
  local deb=(src-tauri/target/release/bundle/deb/*.deb)
  bsdtar -xOf "${deb[0]}" 'data.tar.*' | bsdtar -xf - -C "$pkgdir"
  sed -i 's|^Exec=|Exec=env WEBKIT_DISABLE_DMABUF_RENDERER=1 |' "$pkgdir"/usr/share/applications/*.desktop
}
```

Exercise a resource or sidecar while verifying: an open window does not prove they were found.

## VCS variant (`dsr-foo-git`)

Used only when upstream has no releases or tags. No `.nvchecker.toml`.

```bash
pkgname=dsr-foo-git
pkgver=r0.0000000
makedepends=('git')
provides=("$_name") # with tags (pkgver like 1.2.0.r3.gabc1234): provides=("$_name=${pkgver%%.r*}")
conflicts=("$_name" "$_name-bin" "$_name-git" 'dsr-foo' 'dsr-foo-bin')
source=("$_name::git+$url.git")
sha256sums=('SKIP')

pkgver() {
  cd "$_name"
  local described
  if described=$(git describe --long --tags --abbrev=7 2>/dev/null); then
    sed 's/^v//;s/\([^-]*-g\)/r\1/;s/-/./g' <<<"$described"
  else
    printf 'r%s.%s' "$(git rev-list --count HEAD)" "$(git rev-parse --short=7 HEAD)"
  fi
}
```

Build steps are those of the matching source template, working in `"$_name"`.
