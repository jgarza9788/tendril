#!/usr/bin/env bash
# Builds the release files into dist-release/vX.Y.Z/ from the committed code (never the working
# folder), and publishes nothing:
#   tendril-X.Y.Z.tar.gz                 source, with hnoss included, so it builds on its own
#   tendril-X.Y.Z-1-x86_64.pkg.tar.zst   Arch package (the unit tests run while it builds)
#   tendril-X.Y.Z-x86_64-linux.tar.gz    the binary, statically linked: runs on any x86-64 Linux
#   Tendril-X.Y.Z-x86_64.AppImage        the same binary in an AppImage
#   SHA256SUMS
# Usage: scripts/release/build.sh [commit]      (default HEAD)
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tools="${TOOLS:-$HOME/Work/CaptainFM-tools}"      # holds appimagetool-x86_64.AppImage
commit="${1:-HEAD}"
cd "$repo"

for tool in git odin makepkg bsdtar sha256sum tar; do
    command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 1; }
done
[[ -x "$tools/appimagetool-x86_64.AppImage" ]] || { echo "error: no appimagetool in $tools" >&2; exit 1; }
(cd "$tools" && sha256sum -c --quiet SHA256SUMS) || { echo "error: the tools in $tools do not match their checksums" >&2; exit 1; }
[[ -f libs/hnoss/hnoss.odin ]] || { echo "error: libs/hnoss is empty (git submodule update --init)" >&2; exit 1; }

version="$(git show "$commit:VERSION" | tr -d '[:space:]')"
out="$repo/dist-release/v$version"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rm -rf "$out"; mkdir -p "$out"
echo "==> Building $version from $(git rev-parse --short "$commit")"

echo "==> Source tarball (with hnoss)"
src="tendril-$version"
mkdir -p "$work/$src"
git archive --format=tar "$commit" | tar -x -C "$work/$src"
hnoss="$(git ls-tree "$commit" libs/hnoss | awk '{print $3}')"      # the commit the submodule is pinned to
git -C libs/hnoss archive --format=tar "$hnoss" | tar -x -C "$work/$src/libs/hnoss"
stamp="$(git show -s --format=%ct "$commit")"
tar -C "$work" --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$stamp" -czf "$out/$src.tar.gz" "$src"

echo "==> Arch package (builds and tests inside makepkg)"
cp "$out/$src.tar.gz" "$work/"
git show "$commit:packaging/arch/PKGBUILD" | sed "s/^pkgver=.*/pkgver=$version/" > "$work/PKGBUILD"
(cd "$work" && PKGDEST="$out" makepkg -f --noconfirm --nodeps >"$work/makepkg.log" 2>&1) \
    || { tail -30 "$work/makepkg.log" >&2; echo "error: makepkg failed" >&2; exit 1; }

echo "==> Static binary"
cd "$work/$src"
odin build src -vet -strict-style -warnings-as-errors -o:speed -extra-linker-flags:"-static" \
    -define:TENDRIL_VERSION="$version" -out:"$work/tendril"
if ldd "$work/tendril" >/dev/null 2>&1; then echo "error: the binary is not static" >&2; exit 1; fi
[[ "$("$work/tendril" --version)" == "tendril $version" ]] || { echo "error: wrong version in the binary" >&2; exit 1; }

echo "==> Tarball"
name="tendril-$version-x86_64-linux"
mkdir -p "$work/$name"
install -m755 "$work/tendril" "$work/$name/tendril"
cp README.md LICENSE install.sh uninstall.sh packaging/tendril.desktop packaging/tendril.svg "$work/$name/"
tar -C "$work" --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$stamp" -czf "$out/$name.tar.gz" "$name"

echo "==> AppImage"
packaging/appimage/build.sh "$work/$src" "$work/tendril" "$work/AppDir" "$out/Tendril-$version-x86_64.AppImage" "$tools"

(cd "$out" && sha256sum -- * > SHA256SUMS)
echo "==> Done"
ls -lh "$out"
