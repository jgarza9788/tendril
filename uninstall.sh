#!/usr/bin/env bash
# Removes what install.sh put in PREFIX (default /usr/local). Your settings, servers and
# saved queue in ~/.config/tendril and ~/.local/state/tendril are left alone.
set -euo pipefail
prefix="${PREFIX:-/usr/local}"
rm -f "$prefix/bin/tendril" "$prefix/share/applications/tendril.desktop" \
      "$prefix/share/icons/hicolor/scalable/apps/tendril.svg"
rm -rf "$prefix/share/licenses/tendril"
echo "Removed Tendril from $prefix."
