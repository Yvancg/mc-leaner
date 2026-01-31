#!/bin/bash
# shellcheck shell=bash
# mc-leaner: launchd hygiene module
# Purpose: Heuristically identify orphaned LaunchAgents and LaunchDaemons and optionally relocate their plists to backups
# Safety: Defaults to dry-run; never deletes; moves require explicit `--apply` and per-item confirmation; hard-skips security software

# NOTE: Modules run with strict mode for deterministic failures and auditability.

set -euo pipefail

# Suppress SIGPIPE noise when output is piped to a consumer that exits early (e.g., `head -n`).
# Safety: logging/output ergonomics only; does not affect inspection results.
trap '' PIPE

# Purpose: Provide safe fallbacks when shared helpers are not loaded.
# Safety: Logging only; must not change inspection or cleanup behavior.
if ! type explain_log >/dev/null 2>&1; then
  explain_log() {
    # Purpose: Best-effort verbose logging when --explain is enabled.
    # Safety: Logging only.
    if [[ "${EXPLAIN:-false}" == "true" ]]; then
      log "$@"
    fi
  }
fi

# Ensure shared SERVICE? emitter is available (label-deduped, network-facing heuristics).
if ! command -v service_emit_record >/dev/null 2>&1; then
  _launchd_dir="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
  # shellcheck source=/dev/null
  [[ -f "${_launchd_dir}/../lib/utils.sh" ]] && source "${_launchd_dir}/../lib/utils.sh"
fi

# ----------------------------
# Local temp file helper (do NOT use shared tmpfile() here)
# ----------------------------
_launchd_tmpfile() {
  # Purpose: Create a temp file for this module only.
  # Safety: Creates an empty temp file.
  # Important: must not write anything except the path to stdout.
  mktemp -t mc-leaner.XXXXXX 2>/dev/null || true
}

# ----------------------------
# Module Entry Point
# ----------------------------
run_launchd_module() {
  local mode="$1" apply="$2" backup_dir="$3"
  local inventory_index_file="${4:-}"

  # Inputs
  log "Launchd: mode=${mode} apply=${apply} backup_dir=${backup_dir} inventory_index=${inventory_index_file:-<none>}"

  # Timing (best-effort wall clock duration for this module).
  local _launchd_t0="" _launchd_t1=""
  _launchd_t0="$(/bin/date +%s 2>/dev/null || echo '')"
  LAUNCHD_DUR_S=0

  _launchd_finish_timing() {
    _launchd_t1="$(/bin/date +%s 2>/dev/null || echo '')"
    if [[ -n "${_launchd_t0:-}" && -n "${_launchd_t1:-}" && "${_launchd_t0}" =~ ^[0-9]+$ && "${_launchd_t1}" =~ ^[0-9]+$ ]]; then
      LAUNCHD_DUR_S=$((_launchd_t1 - _launchd_t0))
    else
      LAUNCHD_DUR_S=0
    fi
  }

  local flagged_count=0
  local flagged_items=()

  # Collect identifiers for flagged launchd items (human-readable descriptors).
  # Exported at end as LAUNCHD_FLAGGED_IDS_LIST (newline-delimited).
  local move_fail_count=0
  local move_failures=()

  # Temp files created by this module (cleaned up on return)
  local inventory_keys_file=""
  local active_jobs_file=""
  local _launchd_tmpfiles=()

  _launchd_tmp_cleanup() {
    local f
    for f in "${_launchd_tmpfiles[@]:-}"; do
      [[ -n "$f" && -e "$f" ]] && rm -f "$f" 2>/dev/null || true
    done
  }
  _launchd_on_return() {
    # Ensure we always compute duration and remove temp files.
    _launchd_finish_timing
    _launchd_tmp_cleanup
  }
  trap _launchd_on_return RETURN

  # Precompute inventory keys for fast membership checks (performance)
  if [[ -n "${inventory_index_file}" && -f "${inventory_index_file}" ]]; then
    inventory_keys_file="$(_launchd_tmpfile)"
    if [[ -n "${inventory_keys_file:-}" ]]; then
      _launchd_tmpfiles+=("${inventory_keys_file}")
      # Column 1 contains keys; de-duplicate once (SIGPIPE-safe under piped output)
      {
        LC_ALL=C sort -u < <(cut -f1 "${inventory_index_file}" 2>/dev/null || true) >"${inventory_keys_file}" 2>/dev/null
      } 2>/dev/null || true
    else
      inventory_keys_file=""
    fi
  fi

  # ----------------------------
  # Module Summary Contract
  # ----------------------------
  _launchd_summary_emit() {
    # Purpose: emit a concise end-of-run summary line for global reporting
    # Safety: logging only; does not change behavior
    local checked_plists="$1"

    local msg="checked=${checked_plists} plists; flagged=${flagged_count}"
    if [[ "${move_fail_count}" -gt 0 ]]; then
      msg+="; move_failures=${move_fail_count}"
    fi
    if [[ "${mode}" == "clean" && "${apply}" == "true" ]]; then
      msg+="; apply=enabled (per-item confirm)"
    fi

    summary_add "Launchd" "$msg"
  }

  # ----------------------------
  # Helper: Resolve Program Path
  # ----------------------------
  _launchd_program_path() {
    # Purpose: Extract the executable path from a launchd plist (Program or ProgramArguments[0])
    # Safety: Read-only; used only to reduce false positives before proposing any move
    local plist_path="$1"

    if ! is_cmd plutil; then
      echo ""
      return 0
    fi

    local out=""

    # Try Program first (preferred, unambiguous)
    out="$(plutil -extract Program raw -o - "$plist_path" 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
      echo "$out"
      return 0
    fi

    # Fallback: ProgramArguments[0] (common pattern)
    out="$(plutil -extract ProgramArguments.0 raw -o - "$plist_path" 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
      echo "$out"
      return 0
    fi

    echo ""
  }

  _launchd_program_exists() {
    # Purpose: Confirm whether the resolved launchd program path exists on disk
    local p="$1"
    [[ -n "$p" && -e "$p" ]]
  }

  # ----------------------------
  # Inventory-Based Installed Checks
  # ----------------------------
  _launchd_norm_key() {
    # Purpose: normalize a string to a conservative lookup key (lowercase alnum only)
    # Safety: used only for matching; does not change scan scope
    local s="$1"
    # shellcheck disable=SC2001
    echo "$s" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+//g'
  }

  _inventory_index_has_key() {
    # Purpose: check if inventory index contains key in column 1
    # Expected format: key<TAB>name<TAB>source<TAB>path
    local k="$1"
    [[ -n "$k" && -n "${inventory_keys_file}" && -f "${inventory_keys_file}" ]] || return 1
    grep -qxF "$k" "${inventory_keys_file}" 2>/dev/null
  }

  _inventory_index_name_for_key() {
    # Purpose: Return inventory name (column 2) for a given key (column 1).
    # Expected format: key<TAB>name<TAB>source<TAB>path
    # Safety: Read-only.
    local k="$1"
    [[ -n "$k" && -n "${inventory_index_file:-}" && -f "${inventory_index_file:-}" ]] || return 1

    # First match wins (inventory index is de-duplicated by key in practice).
    /usr/bin/awk -F '\t' -v key="$k" '$1==key{print $2; exit}' "${inventory_index_file}" 2>/dev/null
  }

  _launchd_inventory_owner() {
    # Purpose: Infer an owner string for a launchd label using the inventory index.
    # Strategy (conservative):
    #  - exact key match
    #  - normalized full label key match
    #  - normalized last label component match
    # Safety: Read-only; no guesses beyond inventory-backed matches.
    local label="$1"

    [[ -n "$label" ]] || { echo "Unknown"; return 0; }
    [[ -n "${inventory_index_file:-}" && -f "${inventory_index_file:-}" ]] || { echo "Unknown"; return 0; }

    local name=""

    name="$(_inventory_index_name_for_key "$label" || true)"
    if [[ -n "$name" ]]; then
      echo "$name"
      return 0
    fi

    local n_full
    n_full="$(_launchd_norm_key "$label")"
    if [[ -n "$n_full" ]]; then
      name="$(_inventory_index_name_for_key "$n_full" || true)"
      if [[ -n "$name" ]]; then
        echo "$name"
        return 0
      fi
    fi

    local last="${label##*.}"
    local n_last
    n_last="$(_launchd_norm_key "$last")"
    if [[ -n "$n_last" ]]; then
      name="$(_inventory_index_name_for_key "$n_last" || true)"
      if [[ -n "$name" ]]; then
        echo "$name"
        return 0
      fi
    fi

    echo "Unknown"
  }

  _launchd_label_prefix_owner() {
    # Purpose: Conservative static owner attribution when inventory cannot resolve a launchd label.
    # Safety: Explicit mapping only (no fuzzy matching).
    local label="$1"

    case "$label" in
      com.dropbox.*)
        echo "Dropbox"
        return 0
        ;;
      us.zoom.*)
        echo "Zoom"
        return 0
        ;;
      com.google.keystone.*|com.google.GoogleUpdater.*)
        echo "Google Keystone"
        return 0
        ;;
      *)
        :
        ;;
    esac

    echo ""
  }

  _launchd_label_matches_inventory() {
    # Purpose: reduce false positives by skipping launchd labels that map to installed software
    # Strategy (conservative):
    #  - exact key match against inventory index (bundle id or normalized name keys)
    #  - normalized last component match (common for labels like com.vendor.app.helper)
    local label="$1"

    # If inventory is not available, do not claim a match.
    [[ -n "$label" ]] || return 1
    [[ -n "${inventory_keys_file}" && -f "${inventory_keys_file}" ]] || return 1

    # Exact match (bundle id or normalized key already present)
    if _inventory_index_has_key "$label"; then
      return 0
    fi

    # Normalized full label
    local n_full
    n_full="$(_launchd_norm_key "$label")"
    if [[ -n "$n_full" ]] && _inventory_index_has_key "$n_full"; then
      return 0
    fi

    # Normalized last component after '.'
    local last="${label##*.}"
    local n_last
    n_last="$(_launchd_norm_key "$last")"
    if [[ -n "$n_last" ]] && _inventory_index_has_key "$n_last"; then
      return 0
    fi

    return 1
  }

  # ----------------------------
  # Snapshot Active launchctl Jobs
  # ----------------------------
  log "Scanning active launchctl jobs..."
  active_jobs_file="$(_launchd_tmpfile)"
  if [[ -n "${active_jobs_file:-}" ]]; then
    _launchd_tmpfiles+=("${active_jobs_file}")

    # Helper: determine whether a label is currently loaded (reduces false positives)
    launchctl list 2>/dev/null | awk 'NR>1 {print $3}' 2>/dev/null | grep -v '^-$' 2>/dev/null >"${active_jobs_file}" 2>/dev/null || true
  else
    active_jobs_file=""
  fi

  is_active_job() {
    local job="$1"
    [[ -n "${job:-}" && -n "${active_jobs_file:-}" && -f "${active_jobs_file}" ]] || return 1
    grep -qxF "$job" "${active_jobs_file}" 2>/dev/null
  }

  # ----------------------------
  # Launchd Scan Targets
  # ----------------------------
  log "Checking LaunchAgents/LaunchDaemons..."
  local paths=(
    "/Library/LaunchAgents"
    "/Library/LaunchDaemons"
    "$HOME/Library/LaunchAgents"
    "$HOME/Library/LaunchDaemons"
  )

  # ----------------------------
  # Heuristic Scan
  # ----------------------------
  local checked=0
  local orphan_found=0
  for dir in "${paths[@]}"; do
    [[ -d "$dir" ]] || continue
    for plist_path in "$dir"/*.plist; do
      [[ -f "$plist_path" ]] || continue

      local label
      label=""
      if is_cmd plutil; then
        label="$(plutil -extract Label raw -o - "$plist_path" 2>/dev/null || true)"
      fi
      if [[ -z "${label}" ]]; then
        label="$(defaults read "$plist_path" Label 2>/dev/null || true)"
      fi
      [[ -n "${label:-}" ]] || continue

      local scope
      local persistence
      local owner

      case "$dir" in
        '/Library/LaunchAgents')
          scope="system"
          persistence="login"
          ;;
        '/Library/LaunchDaemons')
          scope="system"
          persistence="boot"
          ;;
        "$HOME"/Library/LaunchAgents)
          scope="user"
          persistence="login"
          ;;
        "$HOME"/Library/LaunchDaemons)
          scope="user"
          persistence="boot"
          ;;
        *)
          scope="user"
          persistence="login"
          ;;
      esac

      # Resolve program path early so we can attribute by exec path when possible.
      local prog
      prog="$(_launchd_program_path "$plist_path")"

      # Owner attribution (inventory-first; conservative fallbacks).
      owner=""

      # 1) Exact bundle-id match (label key).
      if declare -F inventory_lookup_owner_by_bundle_id >/dev/null 2>&1; then
        owner="$(inventory_lookup_owner_by_bundle_id "${label}" 2>/dev/null || true)"
      else
        owner="$(_inventory_index_name_for_key "$label" 2>/dev/null || true)"
      fi

      # 2) Exec path match (preferred when available).
      if [[ -z "${owner}" && -n "${prog}" ]]; then
        if declare -F inventory_lookup_owner_by_path >/dev/null 2>&1; then
          owner="$(inventory_lookup_owner_by_path "${prog}" 2>/dev/null || true)"
        else
          owner="$(_inventory_index_name_for_key "path:${prog}" 2>/dev/null || true)"
        fi
      fi

      # 3) Conservative inventory-backed heuristics.
      if [[ -z "${owner}" ]]; then
        owner="$(_launchd_inventory_owner "${label}" 2>/dev/null || true)"
        [[ "${owner}" == "Unknown" ]] && owner=""
      fi

      # 4) Generic fallback: match launchd label prefixes against installed bundle IDs.
      if [[ -z "${owner}" ]] && declare -F inventory_owner_by_label_prefix >/dev/null 2>&1; then
        local prefix_meta=""
        prefix_meta="$(inventory_owner_by_label_prefix "${label}" "${inventory_index_file:-${INVENTORY_INDEX_FILE:-}}" 2>/dev/null || true)"
        if [[ -n "${prefix_meta}" ]]; then
          local p_owner="" p_how="" p_conf=""
          p_owner="${prefix_meta%%$'\t'*}"
          p_how="${prefix_meta#*$'\t'}"; p_how="${p_how%%$'\t'*}"
          p_conf="${prefix_meta##*$'\t'}"

          owner="${p_owner}"
          explain_log "Launchd owner: ${p_how} (conf=${p_conf}) | label=${label} | owner=${owner}"
        fi
      fi

      # 5) Last resort: small explicit prefix map.
      if [[ -z "${owner}" ]]; then
        local mapped_owner=""
        mapped_owner="$(_launchd_label_prefix_owner "${label}")"
        if [[ -n "$mapped_owner" ]]; then
          owner="$mapped_owner"
          explain_log "Launchd owner: label-prefix-map | label=${label} | owner=${owner}"
        fi
      fi

      [[ -z "${owner}" ]] && owner="Unknown"

      service_emit_record "$scope" "$persistence" "$owner" "" "$label"

      checked=$((checked + 1))

      # HARD SAFETY: never touch security, endpoint protection, or EDR tooling.
      if is_protected_label "$label"; then
        log "SKIP (protected): $plist_path"
        explain_log "  reason: label protected (${label})"
        continue
      fi

      # SAFETY: skip Homebrew-managed services (users should manage these via Homebrew).
      if is_homebrew_service_label "$label"; then
        log "SKIP (homebrew service): $plist_path"
        explain_log "  reason: homebrew-managed label (${label})"
        continue
      fi

      # SAFETY: skip active services to avoid disrupting running processes.
      if is_active_job "$label"; then
        explain_log "SKIP (active job): $plist_path (label: $label)"
        continue
      fi

      # Skip labels that match installed software via inventory index (best-effort guard).
      if _launchd_label_matches_inventory "$label"; then
        explain_log "SKIP (installed-match via inventory): $plist_path (label: $label)"
        continue
      fi

      # SAFETY: if we cannot resolve a program path, skip instead of guessing.
      # This reduces false positives for plists that only define other keys.
      if [[ -z "$prog" ]]; then
        explain_log "SKIP (unknown program): $plist_path (label: $label, program: <none>)"
        continue
      fi

      if ! _launchd_program_exists "$prog"; then
        orphan_found=1
        log "ORPHAN (missing program): $plist_path (label: $label, program: $prog)"
        flagged_count=$((flagged_count + 1))
        flagged_items+=("label: ${label} | program: ${prog} | plist: ${plist_path}")
      else
        explain_log "OK (program exists): $plist_path (label: $label, program: $prog)"
        continue
      fi

      # NOTE: only plists with a missing program path are treated as orphans; confirmation is still required.
      # SAFETY: move only in clean mode with --apply and per-item confirmation.
      if [[ "$mode" == "clean" && "$apply" == "true" ]]; then
        if ask_yes_no "Orphaned launch item detected:\n$plist_path\n\nMove to backup folder?"; then
          # Move contract: safe_move prints the final destination path on success.
          # On failure, it returns non-zero and prints a short diagnostic.
          local move_out
          if move_out="$(safe_move "$plist_path" "$backup_dir" 2>&1)"; then
            log "Moved: $plist_path -> $move_out"
          else
            move_fail_count=$((move_fail_count + 1))
            move_failures+=("$plist_path | failed: $move_out")
            log "Launchd: move failed: $plist_path | $move_out"
          fi
        fi
      fi
    done
  done

  if [[ "$orphan_found" -eq 0 ]]; then
    log "Launchd: no orphaned plists found (by heuristics)."
    explain_log "Launchd: checked ${checked} plists."

    # Export summary variables for the orchestrator, even when nothing is flagged.
    LAUNCHD_FLAGGED_IDS_LIST=""
    LAUNCHD_FLAGGED_IDS_LIST="${LAUNCHD_FLAGGED_IDS_LIST%$'\n'}"
    LAUNCHD_FLAGGED_COUNT="${flagged_count}"
    LAUNCHD_DUR_S="${LAUNCHD_DUR_S:-0}"

    _launchd_summary_emit "${checked}"
    return 0
  fi

  log "Launchd: flagged ${flagged_count} orphaned plist(s)."
  log "Launchd: flagged items:"
  for item in "${flagged_items[@]}"; do
    log "  - ${item}"
  done

  if [[ "$move_fail_count" -gt 0 ]]; then
    log "Launchd: move failures:"
    for f in "${move_failures[@]}"; do
      log "  - ${f}"
    done
  fi

  if [[ "$mode" == "clean" && "$apply" == "true" ]]; then
    log "Launchd: apply mode enabled; items may have been moved only after per-item confirmation."
  else
    log "Launchd: run with --mode clean --apply to move selected items (user-confirmed, reversible)."
  fi

  explain_log "Launchd: checked ${checked} plists."

  # Export flagged identifiers list for run summary consumption.
  LAUNCHD_FLAGGED_IDS_LIST="$({ printf '%s\n' "${flagged_items[@]}"; } 2>/dev/null || true)"
  LAUNCHD_FLAGGED_IDS_LIST="${LAUNCHD_FLAGGED_IDS_LIST%$'\n'}"
  LAUNCHD_FLAGGED_COUNT="${flagged_count}"
  LAUNCHD_DUR_S="${LAUNCHD_DUR_S:-0}"

  _launchd_summary_emit "${checked}"
}
