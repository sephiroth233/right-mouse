#!/bin/bash
set -euo pipefail

# Run only after prepare-release.py. Credentials are supplied by gh locally or
# GH_TOKEN in the release job; this script never pushes or rewrites a Git tag.
if [[ $# -ne 4 ]]; then
    echo 'Usage: publish-local-release.sh REPOSITORY TAG ASSET_DIRECTORY NOTES_FILE' >&2
    exit 2
fi
repo="$1"; tag="$2"; assets_dir="$3"; notes="$4"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]
test -f "$notes"
assets=("$assets_dir"/*.dmg "$assets_dir"/*.sha256 "$assets_dir"/build-info-*.json)
test "${#assets[@]}" -eq 6
for asset in "${assets[@]}"; do test -f "$asset"; done

if existing=$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft 2>/dev/null); then
    if [[ "$existing" != true ]]; then
        echo 'Release already published; refusing to replace its assets.' >&2
        exit 1
    fi
else
    gh release create "$tag" --repo "$repo" --verify-tag --draft \
        --title "RightMouse $tag" --notes-file "$notes"
fi
# Failed uploads leave a draft. A rerun can replace only draft assets.
gh release upload "$tag" "${assets[@]}" --repo "$repo" --clobber
remote_count=$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets | length')
test "$remote_count" -eq 6
gh release edit "$tag" --repo "$repo" --draft=false --prerelease=false \
    --title "RightMouse $tag" --notes-file "$notes"
gh release view "$tag" --repo "$repo" --json url --jq .url
