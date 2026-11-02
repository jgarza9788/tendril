#!/usr/bin/env bash
# Tags the commit and publishes dist-release/vX.Y.Z/ as a GitHub release. Public.
#   publish.sh             stops if the release already exists
#   publish.sh --replace   deletes that release and its tag first
#   publish.sh --yes       does not ask for the final yes
# Run scripts/release/build.sh first, and put the notes in dist-release/notes.md.
# Anything else you want attached (the demo video) can be listed after the options.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"
replace=no; assume=no; extra=()
for a in "$@"; do
    case "$a" in
        --replace) replace=yes ;;
        --yes)     assume=yes ;;
        *)         extra+=("$a") ;;
    esac
done

version="$(tr -d '[:space:]' < VERSION)"
codename="$(tr -d '\n' < CODENAME)"
stage="$(tr -d '\n' < STAGE)"
tag="v$version"
out="dist-release/$tag"
notes="dist-release/notes.md"
title="Tendril $tag $codename ($stage)"

git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "error: push main first, and publish from it" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: commit your changes first" >&2; exit 1; }
[[ -f "$out/SHA256SUMS" ]] || { echo "error: run scripts/release/build.sh first" >&2; exit 1; }
[[ -f "$notes" ]] || { echo "error: write $notes first" >&2; exit 1; }
grep -q 'EDIT:' "$notes" && { echo "error: $notes still has an EDIT: marker" >&2; exit 1; }
(cd "$out" && sha256sum -c --quiet SHA256SUMS)
for f in "${extra[@]}"; do [[ -f "$f" ]] || { echo "error: $f does not exist" >&2; exit 1; }; done

exists=no
gh release view "$tag" >/dev/null 2>&1 && exists=yes
if [[ "$exists" == yes && "$replace" != yes ]]; then
    echo "error: $tag is already released. Use --replace to delete it first." >&2
    exit 1
fi

echo "$title from $(git rev-parse --short HEAD)"
ls -lh "$out" "${extra[@]}"
[[ "$exists" == yes ]] && echo "This DELETES the published $tag release and tag first."
if [[ "$assume" != yes ]]; then
    read -rp "Publish this for everyone? Type yes: " reply
    [[ "$reply" == yes ]] || exit 1
fi

if [[ "$exists" == yes ]]; then
    gh release delete "$tag" --yes --cleanup-tag
fi
git tag -d "$tag" 2>/dev/null || true
git tag -a "$tag" -m "$tag $codename ($stage)"
git push origin "$tag"
flags=(); [[ "$stage" == Beta ]] && flags=(--prerelease)
gh release create "$tag" --title "$title" "${flags[@]}" --verify-tag --notes-file "$notes" "$out"/* "${extra[@]}"
gh release view "$tag" --json url --jq .url
