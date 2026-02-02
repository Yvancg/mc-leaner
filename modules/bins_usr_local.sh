#!/bin/bash
# shellcheck shell=bash
# mc-leaner: /usr/local/bin inspection module
# Purpose: Heuristically identify unmanaged binaries in /usr/local/bin (using Inventory to reduce false positives) and optionally relocate them to backups
# Safety: Defaults to dry-run; never deletes; moves require explicit `--apply` and per-item confirmation


# NOTE: Modules run with strict mode for deterministic failures and auditability.
set -uo pipefail

# ----------------------------
# Module Entry Point
# ----------------------------

run_bins_module() {
  # Contract:
  #   run_bins_module <mode> <apply> <backup_dir> <explain> [inventory_index_file] [brew_bins_file]
  local mode="${1:-scan}"
  local apply="${2:-false}"
  local backup_dir="${3:-}"
  local explain="${4:-false}"
  local inventory_index_file="${5:-}"
  local brew_bins_file="${6:-}"

  # Defensive: some dispatchers have historically passed the inventory path as the
  # 4th argument (where <explain> should be). If <explain> is not a boolean but
  # looks like a file path, treat it as the inventory file and default explain=false.
  if [[ "${explain}" != "true" && "${explain}" != "false" ]]; then
    if [[ -f "${explain}" || "${explain}" == /* ]]; then
      # Shift legacy signature: explain=inventory_index, inventory_index=brew_bins.
      brew_bins_file="${inventory_index_file}"
      inventory_index_file="${explain}"
      explain="false"
    fi
  fi

  # Reserved args for contract consistency.
  : "${mode}" "${backup_dir}" "${explain}"

  # Inputs
  # Export contract fields for run summary consumption (stable even when empty).
  BINS_CHECKED_COUNT="0"
  BINS_FLAGGED_IDS_LIST=""
  BINS_FLAGGED_COUNT="0"

  log "Bins: mode=${mode} apply=${apply} backup_dir=${backup_dir} explain=${explain} inventory_index=$(redact_path_for_log "${inventory_index_file:-}" "${explain}")"
  if [[ "${explain}" == "true" ]]; then
    explain_log "Bins (explain): scanning /usr/local/bin"
  fi

  # Module timing (seconds). Used by the end-of-run timing summary.
  local _bins_t0=""
  local _bins_t1=""
  _bins_t0="$(/bin/date +%s 2>/dev/null || echo '')"
  BINS_DUR_S=0

  # ----------------------------
  # Target Directory
  # ----------------------------
  local dir="/usr/local/bin"
  if [[ ! -d "$dir" ]]; then
    BINS_CHECKED_COUNT="0"
    BINS_FLAGGED_IDS_LIST=""
    BINS_FLAGGED_COUNT="0"
    BINS_DUR_S="${BINS_DUR_S:-0}"
    log "Bins: skipping ${dir} (not present)."
    summary_add "bins" "flagged=0"
    return 0
  fi

  # ----------------------------
  # Inventory (optional): build a key membership set to reduce false positives.
  local inv_keys_file=""
  local -a _bins_tmpfiles
  _bins_tmpfiles=()

  _bins_tmp_cleanup() { tmpfile_cleanup "${_bins_tmpfiles[@]:-}"; }

  _bins_finish_timing() {
    _bins_t1="$(/bin/date +%s 2>/dev/null || echo '')"
    if [[ -n "${_bins_t0:-}" && -n "${_bins_t1:-}" && "${_bins_t0}" =~ ^[0-9]+$ && "${_bins_t1}" =~ ^[0-9]+$ ]]; then
      BINS_DUR_S=$((_bins_t1 - _bins_t0))
    fi
  }

  # Single RETURN trap per function (bash only keeps one handler per signal).
  # Safety: timing + tmp cleanup only; no behavior changes to scan/clean logic.
  _bins_on_return() {
    _bins_finish_timing
    _bins_tmp_cleanup
  }
  trap _bins_on_return RETURN

  if [[ -n "$inventory_index_file" && -s "$inventory_index_file" ]]; then
    inv_keys_file="$(tmpfile_new "mc-leaner.bins")"
    if [[ -n "$inv_keys_file" ]]; then
      _bins_tmpfiles+=("$inv_keys_file")
      # inventory index format: key<TAB>name<TAB>source<TAB>path
      cut -f1 "$inventory_index_file" | LC_ALL=C sort -u > "$inv_keys_file" 2>/dev/null || true
    fi
  fi

  if [[ -z "$inv_keys_file" ]]; then
    log "Bins: inventory index not provided; falling back to heuristics only (may increase false positives)."
    if [[ "${explain}" == "true" ]]; then
      explain_log "Bins (explain): inventory index not provided; using heuristics only"
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
  for bin_path in "$dir"/*; do
    [[ -x "$bin_path" ]] || continue
    local base
    base="$(basename "$bin_path")"
    BINS_CHECKED_COUNT=$((BINS_CHECKED_COUNT + 1))

    # Skip symlinks that resolve to an existing target (common for editor CLIs like `code`)
    # Purpose: avoid flagging valid shims as orphans when they point into an installed app bundle
    if [[ -L "$bin_path" ]]; then
      local resolved=""
      resolved="$(_bins_resolve_symlink_target "$bin_path")"

      # If the symlink resolves to an existing target, treat it as managed and skip.
      if [[ -n "$resolved" && -e "$resolved" ]]; then
        if [[ "${explain}" == "true" ]]; then
          explain_log "Bins: skip symlink target exists: bin=${bin_path} target=${resolved}"
        fi
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

      if [[ "${explain}" == "true" ]]; then
        if [[ -n "${app_ref:-}" ]]; then
          explain_log "Bins: script shim detected: bin=${bin_path} app_ref=${app_ref}"
        else
          explain_log "Bins: script shim scan: no app_ref detected: bin=${bin_path}"
        fi
      fi

      if [[ -n "${app_ref:-}" ]]; then
        if [[ -d "$app_ref" ]]; then
          if [[ "${explain}" == "true" ]]; then
            explain_log "Bins: skip script shim references app: bin=${bin_path} app_ref=${app_ref}"
          fi
          continue
        fi

        # Shim points at a missing app bundle: keep scanning logic but annotate.
        if [[ "${explain}" == "true" ]]; then
          explain_log "Bins: script shim missing app (classified orphan): bin=${bin_path} app_ref=${app_ref}"
        fi
        log "ORPHAN? $bin_path (script shim references missing app: $app_ref)"
        flagged_count=$((flagged_count + 1))
        flagged_items+=("${bin_path}")

        # SAFETY: move only in clean mode with --apply and per-item confirmation.
        if [[ "$mode" == "clean" && "$apply" == "true" ]]; then
          if ask_yes_no "Orphaned binary detected:\n$bin_path\n\nReason: script shim references missing app bundle:\n$app_ref\n\nMove to backup folder?"; then
            local move_out=""
            if move_attempt "$bin_path" "$backup_dir"; then
              move_out="${MOVE_LAST_DEST:-}"
              log "Moved: $bin_path -> $move_out"
            else
              move_failures+=("$bin_path|${MOVE_LAST_MESSAGE:-failed}")
              log "Move failed: $bin_path"
            fi
          fi
        fi

        continue
      fi
    fi

    # Skip binaries that are known to be installed (best-effort inventory guard).
    # WARNING: inventory keys are not a full package receipt system.
    if inv_has_key "$base"; then
      if [[ "${explain}" == "true" ]]; then
        explain_log "Bins: skip inventory match: bin=${bin_path} key=${base}"
      fi
      continue
    fi

    log "ORPHAN? $bin_path"
    flagged_count=$((flagged_count + 1))
    flagged_items+=("${bin_path}")

    # SAFETY: move only in clean mode with --apply and per-item confirmation.
    if [[ "$mode" == "clean" && "$apply" == "true" ]]; then
      if ask_yes_no "Orphaned binary detected:\n$bin_path\n\nMove to backup folder?"; then
        local move_out=""
        if move_attempt "$bin_path" "$backup_dir"; then
          move_out="${MOVE_LAST_DEST:-}"
          log "Moved: $bin_path -> $move_out"
        else
          move_failures+=("$bin_path|${MOVE_LAST_MESSAGE:-failed}")
          log "Move failed: $bin_path"
        fi
      fi
    fi
  done

  if [[ "$flagged_count" -eq 0 ]]; then
    # Keep exported values stable even when nothing is flagged.
    BINS_FLAGGED_IDS_LIST=""
    BINS_FLAGGED_COUNT="0"
    BINS_DUR_S="${BINS_DUR_S:-0}"

    log "Bins: inspected ${BINS_CHECKED_COUNT} item(s); flagged 0."
    summary_add "bins" "flagged=0"
    return 0
  fi

  log "Bins: inspected ${BINS_CHECKED_COUNT} item(s); flagged ${flagged_count}."
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
  # Trim any trailing newline for summary list consumption.
  if [[ -n "${BINS_FLAGGED_IDS_LIST:-}" ]]; then
    BINS_FLAGGED_IDS_LIST="$(printf '%s' "${BINS_FLAGGED_IDS_LIST}" | sed '$s/\n$//')"
  fi
  BINS_FLAGGED_COUNT="${flagged_count}"
  BINS_DUR_S="${BINS_DUR_S:-0}"

  # ----------------------------
  # Summary
  # ----------------------------
  summary_add "bins" "flagged=${flagged_count}"
}

# End of module
