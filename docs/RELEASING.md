# Making a release

A release is two small scripts in `scripts/release/`. Each is commented line by line and can be run alone. Releases are
built from **committed code** (`git archive`), never from the working folder, so commit and push first. `X.Y.Z` is the
version in `VERSION`.

```sh
cd ~/Work/tendril
scripts/release/build.sh            # builds dist-release/vX.Y.Z/ (about a minute). Publishes nothing.
# ...try the files, write dist-release/notes.md, add the demo film (see "What stays by hand")...
scripts/release/publish.sh          # public: shows everything and asks for a yes
```

`./build.sh release` is the same as `scripts/release/build.sh`.

## The parts

| Script | What it does | Time |
|---|---|---|
| `scripts/release/build.sh [commit]` | Builds everything into `dist-release/vX.Y.Z/` from `commit` (default `HEAD`): the source tarball, the Arch package, the static tarball, the AppImage and `SHA256SUMS`. Stops at the first failure. | ~1 min |
| `scripts/release/publish.sh` | Checks, asks for a yes, tags `vX.Y.Z`, pushes the tag and creates the GitHub release with everything in `dist-release/vX.Y.Z/`. Public. | seconds |

### What `build.sh` does, in order

1. **Checks** that `git`, `odin`, `makepkg`, `bsdtar`, `sha256sum` and `tar` exist, that `appimagetool` is in `$TOOLS`
   and matches its recorded checksum, and that `libs/hnoss` is checked out.
2. **Source tarball** `tendril-X.Y.Z.tar.gz`: `git archive` of the commit, plus the hnoss commit the submodule is pinned
   to (`git archive` does not include a submodule's files). hnoss's own `docs/` (12 MB) is left out, and so are the README
   images (`.gitattributes`), so the tarball is about 240 KB and builds on its own. It is reproducible: sorted, owner 0,
   and the commit's own timestamp.
3. **Arch package** `tendril-X.Y.Z-1-x86_64.pkg.tar.zst`: `packaging/arch/PKGBUILD` with `pkgver` set from `VERSION`,
   built from that source tarball by `makepkg`. **`check()` runs `./build.sh test`**, so a failing test stops the release.
4. **Static binary**: built from the extracted tarball with `-extra-linker-flags:-static`. The script refuses to go on if
   `ldd` says it is dynamic, or if `--version` is not `tendril X.Y.Z`.
5. **Tarball** `tendril-X.Y.Z-x86_64-linux.tar.gz`: the binary, `install.sh`, `uninstall.sh`, the desktop file, the
   icon, `README.md` and `LICENSE`.
6. **AppImage** `Tendril-X.Y.Z-x86_64.AppImage`: the same binary, through `packaging/appimage/build.sh`.
7. **`SHA256SUMS`** of the five files.

## Variables

| Name | How to set | Default |
|---|---|---|
| `VERSION` | the one line in the `VERSION` file | `0.1.1` at the time of writing |
| `CODENAME` | the `CODENAME` file, edited by hand each release | v0.1.0 and v0.1.1 *Moon Jelly* |
| `STAGE` | the `STAGE` file. `Beta` makes the GitHub release a pre-release | `Beta` |
| `TOOLS` | environment variable | `~/Work/CaptainFM-tools` (holds `appimagetool-x86_64.AppImage` and `SHA256SUMS`) |
| `commit` | first argument to `build.sh` | `HEAD` |

The release title is `Tendril vX.Y.Z <CODENAME> (<STAGE>)`.

`publish.sh` options: `--yes` skips the confirmation, `--replace` deletes an existing release **and its tag** first, and
any other argument is a file to attach as well.

```sh
TOOLS=~/tools scripts/release/build.sh           # tools somewhere else
scripts/release/publish.sh --yes                 # no question (use with care)
```

## Before you start

1. Everything is committed and pushed to `main`. `publish.sh` refuses a dirty tree, and refuses if `HEAD` is not
   `origin/main`.
2. `./build.sh test` is green and CI is green **on that exact commit** (`gh run list`).
3. Bump the version in every place it lives, then commit and push:
   - `VERSION`, and `CODENAME` / `STAGE` if they change;
   - `pkgver` in `packaging/aur/PKGBUILD` and `packaging/arch/PKGBUILD` (the second is overwritten by `build.sh`, but keep
     it honest), then `cd packaging/aur && makepkg --printsrcinfo > .SRCINFO`;
   - the tag in the README's `Tendril-demo.mp4` link (`releases/download/vX.Y.Z/...`).

## What stays by hand

- **Try the files** somewhere clean, and on an old distro as well as this one. Checked for v0.1.0 on Debian 12 and
  Ubuntu 22.04 (glibc 2.36 and 2.35):
  ```sh
  podman run --rm --network=host -v "$PWD/dist-release/vX.Y.Z:/r:ro" -e APPIMAGE_EXTRACT_AND_RUN=1 debian:12-slim sh -c '
    mkdir /t && tar xzf /r/tendril-*-x86_64-linux.tar.gz -C /t && /t/tendril-*/tendril --version
    cp /r/Tendril-*.AppImage /t/a && chmod +x /t/a && /t/a --version'
  ```
  For a full session, use `ubuntu:22.04` with `apt-get install tmux curl mpv`, an `ao=null` line in
  `~/.config/mpv/mpv.conf`, and a mock server on the host (`python3 tools/mock_jellyfin.py 18130 ctr`): log in, open an
  artist, play a track, press `n`, press `q`, and expect exit code 0.
- **Notes:** write `dist-release/notes.md` in the usual three parts: *What is new* in plain words, *Install*, *Limits*
  (keep the limits from the Reference below). There is no generator: copy the last release's notes and edit. If you
  leave an `EDIT:` marker in it, `publish.sh` refuses.
- **The demo film:** copy it into the release folder under its public name, then rebuild the checksums. Delete
  `SHA256SUMS` first, or `sha256sum -- *` hashes the old file into itself and the check fails:
  ```sh
  cp ~/Videos/Tendirl-demo.mp4 dist-release/vX.Y.Z/Tendril-demo.mp4
  (cd dist-release/vX.Y.Z && rm -f SHA256SUMS && sha256sum -- * > SHA256SUMS && sha256sum -c --quiet SHA256SUMS)
  ```
  It is not in the repo (15 MB); only the README's GIF and screenshots are.
- **Publish:** show the file list, `SHA256SUMS` and `notes.md`, and get a yes first. Never move or delete a tag that is
  already published without the owner saying so; for a fix, release a new version. To add or replace files on an
  existing release: `gh release upload vX.Y.Z <files> --clobber`.

## After

Check the release page, then:

```sh
gh release download vX.Y.Z -p SHA256SUMS -p '*.AppImage' && sha256sum -c --ignore-missing SHA256SUMS
```

Make sure the README's links and images still resolve (`curl -sIL <url>`), update `todo.md`, and push the AUR package
(next section) when it exists.

## The AUR

Done by hand, after `publish.sh`, because the PKGBUILD needs the pushed tag. It is **not published yet**: it needs an
AUR account with an SSH key, and pushing is public, so get a yes first.

| Package | Installs | `source` |
|---|---|---|
| `tendril` | builds from source (about 40 s: `odin`, `clang`; runs the tests) | `git+…/tendril.git#tag=v$pkgver`, plus hnoss pinned with `#commit=$_hnoss` |
| `tendril-bin` *(not written)* | the prebuilt tarball (`provides=(tendril)`, `conflicts=(tendril)`) | `tendril-$pkgver-x86_64-linux.tar.gz` from the release page, with the checksum from `SHA256SUMS` |

`packaging/aur/PKGBUILD` is the AUR one; `packaging/arch/PKGBUILD` is the one the release scripts use (it expects the
tarball `build.sh` makes). `packaging/aur/PKGBUILD` was built from the real `v0.1.0` tag and ran its tests. For each
update:

```sh
git clone ssh://aur@aur.archlinux.org/tendril.git        # once
cp packaging/aur/PKGBUILD packaging/aur/.SRCINFO tendril/ # pkgver already bumped, see "Before you start"
cd tendril && makepkg -si                                 # test in a clean Arch container: tendril --version
git add PKGBUILD .SRCINFO && git commit -m "tendril $VERSION" && git push
```

Rules: the AUR repo holds only `PKGBUILD`, `.SRCINFO` and small files; never push a binary. `sha256sums` stay `SKIP` for
git sources. **The pinned `_hnoss` commit must be the one the release was built and tested with**
(`git ls-tree HEAD libs/hnoss`). Once the package is live, remove "not published yet" from the README and add the
`yay -S tendril` line to the release notes.

---

## Reference

**What is supported:** Linux x86-64, a truecolor terminal, `mpv` and `curl` installed. Developed and tested on Arch Linux
with Hyprland; checked on Debian 12 and Ubuntu 22.04 containers (v0.1.0). Shipped: the Arch package, a tarball
(`install.sh` into `/usr/local` or `PREFIX=`), and the AppImage. Not shipped, on purpose: `.deb`, `.rpm` and Flatpak.
Other CPUs, macOS and Windows are not supported.

**Why static:** the tarball and the AppImage hold a statically linked binary (`-extra-linker-flags:-static`). A normal
build from this rolling distro needs glibc 2.44, which does not start on Debian or Ubuntu LTS. Tendril never resolves
names itself (curl does the networking in a child process), so static glibc has nothing to go wrong. The Arch package is
a normal dynamic build, which is the right thing for pacman.

**AppImage limits (put them in the notes):**
- `mpv` and `curl` are **not bundled**: they are large and tied to the system, so they must be installed.
- Running an AppImage needs FUSE on the host (`libfuse2`), or set `APPIMAGE_EXTRACT_AND_RUN=1`.
- Tendril is a terminal program. Its `AppRun` runs it directly when a terminal is attached; otherwise it looks for
  `$TERMINAL`, then `foot`, `alacritty`, `kitty`, `ghostty`, `wezterm`, `konsole`, `xfce4-terminal`, `gnome-terminal`,
  `tilix` or `xterm`. That fallback has only been read, not tried from a file manager.

**In every package:** the `tendril` binary, `tendril.desktop` (`Terminal=true`, so launchers open it in a terminal), the
icon `tendril.svg`, and `LICENSE`. The Arch package also installs `README.md`; the tarball adds `install.sh` and
`uninstall.sh`. Runtime dependencies: `mpv`, `curl`. Optional: `pipewire-pulse` (`parec` and `pactl`, for the real
audio spectrum; without them the visualizer is a simulation) and `playerctl` (control from the shell).

**Rules:**
- Never write into `$HOME` from a package script. `install.sh` defaults to `/usr/local`, and `uninstall.sh` leaves
  `~/.config/tendril` and `~/.local/state/tendril` alone.
- `packaging/arch/PKGBUILD` and the AUR one need `options=('!debug')`, or `makepkg` also makes a useless
  `tendril-debug` package that ends up in the release folder.
- `git archive` does not include submodule files. `build.sh` adds hnoss itself; do not replace that with a plain
  `git archive`.
- GitHub's `/releases/latest/` ignores pre-releases, so the README links the film by tag, not by `latest`.
- `dist-release/` is git-ignored: it holds build output and `notes.md`, which is written by hand for each release.

**The demo film** is made by the scripts in `demo/` (see `demo/README.md`) and is not part of the build.

**Past releases:** v0.1.0 *Moon Jelly* (Beta), the first release; v0.1.1 *Moon Jelly* (Beta), the README and the demo film.
