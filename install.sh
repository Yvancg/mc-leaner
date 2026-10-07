#!/bin/bash
# mc-leaner: latest-release installer
# Purpose: Resolve the latest published GitHub release, download its source archive, and launch McLeaner
# Safety: Never overwrites an existing install directory or archive; performs no privileged filesystem changes

set -euo pipefail

# ----------------------------
# Release Resolution
# ----------------------------

REPO="Yvancg/mc-leaner"
LATEST_RELEASE_URL="https://github.com/$REPO/releases/latest"

resolved_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "$LATEST_RELEASE_URL")"
tag="${resolved_url##*/}"

case "$tag" in
  v[0-9]*)
    ;;
  *)
    printf 'Error: could not resolve a valid McLeaner release tag.\n' >&2
    exit 1
    ;;
esac

version="${tag#v}"
install_dir="mc-leaner-$version"
archive_path="$install_dir.tar.gz"

# ----------------------------
# Safety Checks
# ----------------------------

# HARD SAFETY: refuse to overwrite an existing download or install directory.
if [[ -e "$install_dir" || -e "$archive_path" ]]; then
  printf 'Error: %s or %s already exists. Move or rename it, then retry.\n' "$install_dir" "$archive_path" >&2
  exit 1
fi

# ----------------------------
# Download And Extract
# ----------------------------

archive_url="https://github.com/$REPO/archive/refs/tags/$tag.tar.gz"

printf 'McLeaner release: %s\n' "$tag"
printf 'Downloading %s\n' "$archive_url"

curl -fL "$archive_url" -o "$archive_path"
mkdir "$install_dir"
tar -xzf "$archive_path" --strip-components=1 -C "$install_dir"

if [[ ! -f "$install_dir/mc-leaner.sh" ]]; then
  printf 'Error: release archive does not contain mc-leaner.sh.\n' >&2
  exit 1
fi

# ----------------------------
# Launch
# ----------------------------

cd "$install_dir"
exec bash mc-leaner.sh "$@"
