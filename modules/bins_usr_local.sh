#!/bin/bash
# shellcheck shell=bash
# mc-leaner: /usr/local/bin inspection module
# Purpose: Heuristically identify unmanaged binaries in /usr/local/bin (using Inventory to reduce false positives) and optionally relocate them to backups
# Safety: Defaults to dry-run; never deletes; moves require explicit `--apply` and per-item confirmation


# NOTE: Modules run with strict mode for deterministic failures and auditability.
set -euo pipefail

# ----------------------------
# Module Entry Point
# ----------------------------

run_bins_module() {
  local mode="${1:-scan}"
  local apply="${2:-false}"
  local backup_dir="${3:-}"
  local inventory_index_file="${4:-}"

  # Reserved args for contract consistency.
  : "${mode}" "${backup_dir}"

  # Inputs
  log "Bins: mode=${mode} apply=${apply} backup_dir=${backup_dir} inventory_index=${inventory_index_file:-<none>}"

  # Export flagged identifiers list for run summary consumption (stable contract even when empty).
  BINS_FLAGGED_IDS_LIST=""
  BINS_FLAGGED_COUNT="0"

  # ----------------------------
  # Target Directory
  # ----------------------------
  local dir="/usr/local/bin"
  if [[ ! -d "$dir" ]]; then
    log "Skipping $dir (not present)."
    return 0
  fi

  # ----------------------------
  # Inventory (optional): build a key membership set to reduce false positives.
  local inv_keys_file=""
  local -a _bins_tmpfiles
  _bins_tmpfiles=()

  _bins_tmp_cleanup() {
    local f
    for f in "${_bins_tmpfiles[@]:-}"; do
      [[ -n "$f" && -e "$f" ]] && rm -f "$f" 2>/dev/null || true
    done
  }

  # Single RETURN trap per function (bash only keeps one handler per signal).
  trap _bins_tmp_cleanup RETURN

  if [[ -n "$inventory_index_file" && -s "$inventory_index_file" ]]; then
    inv_keys_file="$(mktemp -t mc-leaner_bins_invkeys.XXXXXX 2>/dev/null || true)"
    if [[ -n "$inv_keys_file" ]]; then
      _bins_tmpfiles+=("$inv_keys_file")
      # inventory index format: key<TAB>name<TAB>source<TAB>path
      cut -f1 "$inventory_index_file" | LC_ALL=C sort -u > "$inv_keys_file" 2>/dev/null || true
    fi
  fi

  # Returns 0 (true) when the inventory key exists.
  # Implementation note: bash 3.2 has no associative arrays, so we do a fast exact-line check.
  inv_has_key() {
    local k="$1"
    [[ -n "${inv_keys_file:-}" && -s "${inv_keys_file:-}" ]] || return 1
    LC_ALL=C grep -Fqx -- "$k" "$inv_keys_file" 2>/dev/null
  }
  # ----------------------------

  # Resolve a symlink target to an absolute, physical path (best-effort).
  # Contract:
  #   _bins_resolve_symlink_target <symlink_path>
  # Output:
  #   prints resolved absolute path to stdout, or empty string if it cannot be resolved.
  # Safety: read-only; does not modify filesystem.
  _bins_resolve_symlink_target() {
    local link_path="$1"
    [[ -n "${link_path:-}" ]] || { printf '%s' ""; return 0; }

    # Prefer shared fs helper when available.
    if command -v fs_resolve_symlink_target_physical >/dev/null 2>&1; then
      fs_resolve_symlink_target_physical "$link_path" 2>/dev/null || true
      return 0
    fi

    # Fallback (local best-effort) if lib/fs.sh is not available in this runtime.
    command -v readlink >/dev/null 2>&1 || { printf '%s' ""; return 0; }

    local cur="$link_path"
    local target=""
    local dir=""
    local i=0

    # Limit resolution depth to avoid cycles.
    while [[ $i -lt 40 ]]; do
      [[ -L "$cur" ]] || break
      target="$(readlink "$cur" 2>/dev/null || true)"
      [[ -n "${target:-}" ]] || { printf '%s' ""; return 0; }

      if [[ "$target" != /* ]]; then
        dir="$(cd "$(dirname "$cur")" 2>/dev/null && pwd -P 2>/dev/null || true)"
        [[ -n "${dir:-}" ]] || { printf '%s' ""; return 0; }
        cur="$dir/$target"
      else
        cur="$target"
      fi
      i=$((i + 1))
    done

    if [[ -e "$cur" ]]; then
      dir="$(cd "$(dirname "$cur")" 2>/dev/null && pwd -P 2>/dev/null || true)"
      if [[ -n "${dir:-}" ]]; then
        printf '%s' "$dir/$(basename "$cur" 2>/dev/null || printf '%s' "$cur")"
        return 0
      fi
      printf '%s' "$cur"
      return 0
    fi

    printf '%s' ""
  }

  # Best-effort: detect whether a file is a small shebang script that references a macOS .app bundle.
  # Contract:
  #   _bins_script_shim_app_bundle_ref <file>
  # Output:
  #   prints an absolute path to the referenced .app bundle (or empty string).
  # Safety: read-only.
  _bins_script_shim_app_bundle_ref() {
    local p="$1"
    [[ -n "${p:-}" ]] || { printf '%s' ""; return 0; }

    # Prefer shared fs helper when available.
    if command -v fs_script_shim_app_bundle_ref >/dev/null 2>&1; then
      fs_script_shim_app_bundle_ref "$p" 2>/dev/null || true
      return 0
    fi

    # Fallback: no detection if helper not present.
    printf '%s' ""
  }

  # Heuristic Scan
  # ----------------------------
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
      resolved="$(_bins_resolve_symlink_target "$bin_path")"

      # If the symlink resolves to an existing target, treat it as managed and skip.
      if [[ -n "$resolved" && -e "$resolved" ]]; then
        log "SKIP (symlink target exists): $bin_path -> $resolved"
        continue
      fi
    fi

    # Skip script shims that reference an installed app bundle.
    # Purpose: avoid flagging launcher scripts that are not managed by Homebrew.
    # Safety: read-only; best-effort.
    # Notes:
    #   - If a shim references an existing .app bundle, treat it as managed.
    #   - If a shim references a missing .app bundle, flag it (likely stale shim).
    if [[ -f "$bin_path" && ! -L "$bin_path" ]]; then
      local app_ref=""
      app_ref="$(_bins_script_shim_app_bundle_ref "$bin_path")"

      if [[ "${EXPLAIN:-false}" == "true" ]]; then
        if [[ -n "${app_ref:-}" ]]; then
          explain_log "Bins: script shim detected: bin=${bin_path} app_ref=${app_ref}"
        else
          explain_log "Bins: script shim scan: no app_ref detected: bin=${bin_path}"
        fi
      fi

      if [[ -n "${app_ref:-}" ]]; then
        if [[ -d "$app_ref" ]]; then
          log "SKIP (script shim references app): $bin_path -> $app_ref"
          continue
        fi

        # Shim points at a missing app bundle: keep scanning logic but annotate.
        explain_log "Bins: script shim missing app (classified orphan): bin=${bin_path} app_ref=${app_ref}"
        log "ORPHAN? $bin_path (script shim references missing app: $app_ref)"
        flagged_count=$((flagged_count + 1))
        flagged_items+=("${bin_path}")

        # SAFETY: move only in clean mode with --apply and per-item confirmation.
        if [[ "$mode" == "clean" && "$apply" == "true" ]]; then
          if ask_yes_no "Orphaned binary detected:\n$bin_path\n\nReason: script shim references missing app bundle:\n$app_ref\n\nMove to backup folder?"; then
            local move_out=""
            if ! move_out="$(safe_move "$bin_path" "$backup_dir" 2>&1)"; then
              move_failures+=("$bin_path|$move_out")
              log "Move failed: $bin_path"
            else
              log "Moved: $bin_path -> $move_out"
            fi
          fi
        fi

        continue
      fi
    fi

    # Skip binaries that are known to be installed (best-effort inventory guard).
    # WARNING: inventory keys are not a full package receipt system.
    if inv_has_key "$base"; then
      log "SKIP (inventory match): $bin_path (key=$base)"
      continue
    fi

    log "ORPHAN? $bin_path"
    flagged_count=$((flagged_count + 1))
    flagged_items+=("${bin_path}")

    # SAFETY: move only in clean mode with --apply and per-item confirmation.
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

  if [[ "$flagged_count" -eq 0 ]]; then
    # Keep exported values stable even when nothing is flagged.
    BINS_FLAGGED_IDS_LIST=""
    BINS_FLAGGED_COUNT="0"

    log "No orphaned /usr/local/bin items found (by heuristics)."
    summary_add "bins" "flagged=0"
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

  # Export flagged identifiers list for run summary consumption.
  BINS_FLAGGED_IDS_LIST="$({ printf '%s\n' "${flagged_items[@]:-}"; } 2>/dev/null || true)"
  BINS_FLAGGED_COUNT="${flagged_count}"

  # ----------------------------
  # Summary
  # ----------------------------
  summary_add "bins" "flagged=${flagged_count}"
}

# End of module