# Making a release

A release is two scripts in `scripts/release/`, run from the repo. Releases are built from **committed code**
(`git archive`), never from the working folder, so commit first.

```sh
scripts/release/build.sh            # builds dist-release/vX.Y.Z/ (about two minutes). Publishes nothing.
# ...try the files, write dist-release/notes.md...
scripts/release/publish.sh          # tags, pushes the tag, creates the GitHub release. Public: asks for a yes.
```

`X.Y.Z` is the one line in `VERSION`. The release's name comes from `CODENAME` and `STAGE` (a `Beta` stage makes it a
GitHub pre-release): the title is `Tendril vX.Y.Z <codename> (<stage>)`.

## What `build.sh` makes

| File | What it is |
|---|---|
| `tendril-X.Y.Z.tar.gz` | The source with hnoss (the TUI library) included, so it builds on its own. |
| `tendril-X.Y.Z-1-x86_64.pkg.tar.zst` | The Arch package, from `packaging/arch/PKGBUILD`. `makepkg` builds it and **runs the unit tests** as it does. |
| `tendril-X.Y.Z-x86_64-linux.tar.gz` | The binary, with `install.sh` and `uninstall.sh`. |
| `Tendril-X.Y.Z-x86_64.AppImage` | The same binary, in an AppImage (`packaging/appimage/`). |
| `SHA256SUMS` | Checksums of the above. |

The tarball and the AppImage hold a **statically linked** binary (`-extra-linker-flags:-static`), so they have no
minimum glibc and run on any x86-64 Linux. The script refuses to continue if the binary is not static or reports the
wrong version. The AppImage tools come from `~/Work/CaptainFM-tools` (override with `TOOLS=`); their checksums are
checked first.

## Before you publish

1. Everything committed and pushed to `main`; `publish.sh` refuses otherwise.
2. `./build.sh test` is green and CI is green.
3. Try the files in a clean place, on an old distro as well as this one. For example:
   ```sh
   podman run --rm --network=host -v "$PWD/dist-release/vX.Y.Z:/r:ro" debian:12 sh -c \
     'tar xzf /r/tendril-*-x86_64-linux.tar.gz -C /tmp && /tmp/tendril-*/tendril --version'
   ```
4. Write `dist-release/notes.md` (What is new / Install / Limits, like the earlier projects'). `publish.sh` refuses if
   it still contains an `EDIT:` marker.

## Publishing

`publish.sh` tags `vX.Y.Z`, pushes the tag and creates the release with everything in `dist-release/vX.Y.Z/`. Pass
extra files after the options to attach them too (the demo film). `--replace` deletes an existing release and tag first;
`--yes` skips the confirmation.

## The AUR

`packaging/aur/PKGBUILD` builds from the GitHub tag and pins the hnoss commit. After a release, update `pkgver`, run
`makepkg --printsrcinfo > .SRCINFO` in that folder, and push both files to the AUR repository.

## The demo film

`demo/` holds the scripts that record and render the film (see `demo/README.md`). It is not part of the build; attach
the result to the release by hand.
