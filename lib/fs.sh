#!/bin/bash
# mc-leaner: filesystem safety helpers
# Purpose: Provide small, auditable filesystem primitives used by modules (create backup dirs, move files safely)
# Safety: Never deletes; uses `sudo` only when required to relocate protected files

set -euo pipefail

# ----------------------------
# Directory helpers
# ----------------------------

ensure_dir() { mkdir -p "$1"; }

# ----------------------------
# Safe relocation
# ----------------------------

# Purpose: Move a single file into a backup directory, preserving its filename
# Safety: Uses `sudo` only if the source directory is not writable by the current user
safe_move() {
  local src="$1"
  local dst_dir="$2"

  # No-op if the source does not exist (modules may race with system changes)
  [[ -e "$src" ]] || return 0
  ensure_dir "$dst_dir"

  local base
  base="$(basename "$src")"
  local dst="$dst_dir/$base"

  # SAFETY: only elevate privileges when required to move files from protected locations
  if [[ -w "$(dirname "$src")" ]]; then
    mv "$src" "$dst"
  else
    sudo mv "$src" "$dst"
  fi
}

# End of library
