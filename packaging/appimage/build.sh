#!/usr/bin/env bash
# Builds the AppImage around an already-built binary.
#   build.sh <source folder> <binary> <AppDir> <output file> <folder holding appimagetool>
# The binary is statically linked, so there is nothing to bundle and no minimum glibc.
# mpv and curl are used from the host: they are too large and too tied to the system to ship.
set -euo pipefail
source="$1" binary="$2" appdir="$3" output="$4" tools="$5"

mkdir -p "$appdir/usr/bin"
install -m755 "$binary" "$appdir/usr/bin/tendril"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -m755 "$here/AppRun" "$appdir/AppRun"
install -m644 "$source/packaging/tendril.desktop" "$appdir/tendril.desktop"
install -m644 "$source/packaging/tendril.svg" "$appdir/tendril.svg"
ln -sf tendril.svg "$appdir/.DirIcon"
install -Dm644 "$source/LICENSE" "$appdir/usr/share/licenses/tendril/LICENSE"
ARCH=x86_64 "$tools/appimagetool-x86_64.AppImage" --no-appstream "$appdir" "$output" >/dev/null 2>&1
