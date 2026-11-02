#!/usr/bin/env bash
# Installs the tendril binary from a release tarball.
#   ./install.sh                  into /usr/local (needs write access, e.g. sudo)
#   PREFIX=~/.local ./install.sh  into your home folder
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prefix="${PREFIX:-/usr/local}"
[[ -x "$here/tendril" ]] || { echo "error: no tendril binary next to install.sh (use a release tarball)" >&2; exit 1; }
install -Dm755 "$here/tendril" "$prefix/bin/tendril"
install -Dm644 "$here/tendril.desktop" "$prefix/share/applications/tendril.desktop"
install -Dm644 "$here/tendril.svg" "$prefix/share/icons/hicolor/scalable/apps/tendril.svg"
install -Dm644 "$here/LICENSE" "$prefix/share/licenses/tendril/LICENSE"
echo "Installed to $prefix. Tendril needs mpv and curl: sudo pacman -S mpv curl (or your distro's equivalent)."
case ":$PATH:" in *":$prefix/bin:"*) ;; *) echo "Note: $prefix/bin is not on your PATH." ;; esac
