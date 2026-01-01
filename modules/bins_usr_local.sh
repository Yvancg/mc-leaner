#!/bin/bash
set -euo pipefail

run_bins_module() {
  local mode="$1" apply="$2" backup_dir="$3"
  local brew_formulae_file="$4"

  local dir="/usr/local/bin"
  [[ -d "$dir" ]] || { log "Skipping $dir (not present)."; return 0; }

  log "Checking $dir for orphaned binaries (heuristic)..."
  for bin_path in "$dir"/*; do
    [[ -x "$bin_path" ]] || continue
    local base
    base="$(basename "$bin_path")"

    if [[ -s "$brew_formulae_file" ]] && grep -qF "$base" "$brew_formulae_file"; then
      continue
    fi

    log "ORPHAN? $bin_path"

    if [[ "$mode" == "clean" && "$apply" == "true" ]]; then
      if ask_yes_no "Orphaned binary detected:\n$bin_path\n\nMove to backup folder?"; then
        safe_move "$bin_path" "$backup_dir"
        log "Moved: $bin_path"
      fi
    fi
  done
}
