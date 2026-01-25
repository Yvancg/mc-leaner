#!/bin/bash
# shellcheck shell=bash
# mc-leaner: /usr/local/bin inspection module
# Purpose: Heuristically identify unmanaged binaries in /usr/local/bin (using Inventory to reduce false positives) and optionally relocate them to backups
# Safety: Defaults to dry-run; never deletes; moves require explicit `--apply` and per-item confirmation

set -euo pipefail

# ----------------------------
# Module entry point
# ----------------------------

run_bins_module() {
  local mode="$1" apply="$2" backup_dir="$3"
  local inventory_index_file="${4:-}"

  # ----------------------------
  # Target directory
  # ----------------------------
  local dir="/usr/local/bin"
  if [[ ! -d "$dir" ]]; then
    log "Skipping $dir (not present)."
    return 0
  fi

  # ----------------------------
  # Inventory (optional): build membership set (file of keys)
  local inv_keys_file=""
  if [[ -n "$inventory_index_file" && -s "$inventory_index_file" ]]; then
    inv_keys_file="$(mktemp -t mc-leaner_bins_invkeys.XXXXXX)"
    # inventory index format: key<TAB>name<TAB>source<TAB>path
    cut -f1 "$inventory_index_file" | LC_ALL=C sort -u > "$inv_keys_file" || true
    trap 'rm -f "$inv_keys_file" 2>/dev/null || true' RETURN
  fi

  # Build a fast membership map for keys (awk associative array)
  # Note: avoids O(N) grep per binary when /usr/local/bin is large.
  local inv_keys_map=""
  if [[ -n "$inv_keys_file" && -s "$inv_keys_file" ]]; then
    inv_keys_map="$inv_keys_file"
  fi

  # Fast key lookup via awk map. Returns 0 (true) if key exists.
  inv_has_key() {
    local k="$1"
    [[ -n "$inv_keys_map" && -s "$inv_keys_map" ]] || return 1
    awk -v k="$k" 'BEGIN{found=0} $0==k{found=1; exit} END{exit(found?0:1)}' "$inv_keys_map" 2>/dev/null
  }
  # ----------------------------
  # Heuristic scan
  # ----------------------------
  local found=0
  local flagged_count=0
  local flagged_items=()
  local move_failures=()
  log "Checking $dir for orphaned binaries (heuristic)..."
  if [[ -z "$inv_keys_file" ]]; then
    log "Bins: inventory index not provided; falling back to heuristics only (may increase false positives)."
  fi
  for bin_path in "$dir"/*; do
    [[ -x "$bin_path" ]] || continue
    local base
    base="$(basename "$bin_path")"

    # Skip symlinks that resolve to an existing target (common for editor CLIs like `code`)
    # Purpose: avoid flagging valid shims as orphans when they point into an installed app bundle
    if [[ -L "$bin_path" ]]; then
      local resolved=""

      # Prefer realpath-style resolution when available (handles relative symlinks cleanly)
      if is_cmd python3; then
        resolved="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$bin_path" 2>/dev/null || true)"
      fi

      # Fallback: basic readlink resolution (may be relative)
      if [[ -z "$resolved" ]]; then
        resolved="$(readlink "$bin_path" 2>/dev/null || echo "")"
        if [[ -n "$resolved" && "$resolved" != /* ]]; then
          resolved="$(cd "$(dirname "$bin_path")" 2>/dev/null && cd "$(dirname "$resolved")" 2>/dev/null && pwd)/$(basename "$resolved")"
        fi
      fi

      if [[ -n "$resolved" && -e "$resolved" ]]; then
        log "SKIP (symlink target exists): $bin_path -> $resolved"
        continue
      fi
    fi

    # Skip small script shims that reference an installed app bundle
    # Purpose: avoid flagging launcher scripts that are not managed by Homebrew
    if [[ -f "$bin_path" ]]; then
      local head1
      head1="$(head -n 1 "$bin_path" 2>/dev/null || true)"
      if [[ "$head1" == "#!"* ]]; then
        # Only scan a small prefix to avoid reading large files.
        local app_ref
        app_ref="$(head -c 4096 "$bin_path" 2>/dev/null | grep -Eo '/Applications/[^\"\\n]+\.app' | head -n 1 || true)"
        if [[ -n "$app_ref" && -d "$app_ref" ]]; then
          log "SKIP (script shim references app): $bin_path -> $app_ref"
          continue
        fi
      fi
    fi
    # Skip known managed CLI shims that are not installed via Homebrew
    # Note: Keep this list minimal; prefer deterministic checks above.
    case "$base" in
      code)
        log "SKIP (known shim): $bin_path"
        continue
        ;;
    esac

    # Skip binaries that are known to be installed (brew formula/cask keys and app-derived keys)
    # Note: This is a best-effort guard; later we can add pkg receipts vs standalone binary detection.
    if inv_has_key "$base"; then
      log "SKIP (inventory match): $bin_path (key=$base)"
      continue
    fi

    found=1
    log "ORPHAN? $bin_path"
    flagged_count=$((flagged_count + 1))
    flagged_items+=("${bin_path}")

    # SAFETY: only move items when explicitly running in clean mode with --apply
    if [[ "$mode" == "clean" && "$apply" == "true" ]]; then
      if ask_yes_no "Orphaned binary detected:\n$bin_path\n\nMove to backup folder?"; then
        local move_out=""
        if ! move_out="$(safe_move "$bin_path" "$backup_dir" 2>&1)"; then
          move_failures+=("$bin_path|$move_out")
          log "Move failed: $bin_path"
        else
          log "Moved: $bin_path -> $move_out"
        fi
      fi
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    log "No orphaned /usr/local/bin items found (by heuristics)."
    return 0
  fi

  log "Bins: flagged ${flagged_count} item(s) in ${dir}."
  log "Bins: flagged items:"
  for item in "${flagged_items[@]}"; do
    log "  - ${item}"
  done

  if [[ "$mode" == "clean" && "$apply" == "true" ]]; then
    log "Bins: apply mode enabled; items may have been moved only after per-item confirmation."
  else
    log "Bins: run with --mode clean --apply to move selected items (user-confirmed, reversible)."
  fi

  if [[ ${#move_failures[@]} -gt 0 ]]; then
    log "Bins: move failures:"
    local mf
    for mf in "${move_failures[@]}"; do
      local src="${mf%%|*}"
      local err="${mf#*|}"
      log "  - ${src} | failed(permission): ${err}"
    done
  fi

  # ----------------------------
  # Summary
  # ----------------------------
  if [[ "$found" -eq 1 ]]; then
    summary_add "bins" "flagged=${flagged_count}"
  else
    summary_add "bins" "flagged=0"
  fi
}

# End of module