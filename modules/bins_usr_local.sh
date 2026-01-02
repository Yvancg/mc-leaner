#!/bin/bash
# mc-leaner: /usr/local/bin inspection module
# Purpose: Heuristically identify unmanaged binaries in /usr/local/bin and optionally relocate them to backups
# Safety: Defaults to dry-run; never deletes; moves require explicit `--apply` and per-item confirmation

set -euo pipefail

# ----------------------------
# Module entry point
# ----------------------------

run_bins_module() {
  local mode="$1" apply="$2" backup_dir="$3"
  local brew_formulae_file="$4"

  # ----------------------------
  # Target directory
  # ----------------------------
  local dir="/usr/local/bin"
  if [[ ! -d "$dir" ]]; then
    log "Skipping $dir (not present)."
    return 0
  fi

  # ----------------------------
  # Heuristic scan
  # ----------------------------
  log "Checking $dir for orphaned binaries (heuristic)..."
  for bin_path in "$dir"/*; do
    [[ -x "$bin_path" ]] || continue
    local base
    base="$(basename "$bin_path")"

    # Skip binaries that appear to be managed by Homebrew (reduces false positives)
    if [[ -s "$brew_formulae_file" ]] && grep -qF "$base" "$brew_formulae_file"; then
      continue
    fi

    log "ORPHAN? $bin_path"

    # SAFETY: only move items when explicitly running in clean mode with --apply
    if [[ "$mode" == "clean" && "$apply" == "true" ]]; then
      if ask_yes_no "Orphaned binary detected:\n$bin_path\n\nMove to backup folder?"; then
        safe_move "$bin_path" "$backup_dir"
        log "Moved: $bin_path"
      fi
    fi
  done
}

# End of module