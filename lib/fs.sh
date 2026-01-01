#!/bin/bash
set -euo pipefail

ensure_dir() { mkdir -p "$1"; }

# Move file to backup dir, preserving filename.
# Uses sudo automatically if needed.
safe_move() {
  local src="$1"
  local dst_dir="$2"

  [[ -e "$src" ]] || return 0
  ensure_dir "$dst_dir"

  local base
  base="$(basename "$src")"
  local dst="$dst_dir/$base"

  if [[ -w "$(dirname "$src")" ]]; then
    mv "$src" "$dst"
  else
    sudo mv "$src" "$dst"
  fi
}
