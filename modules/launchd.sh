#!/bin/bash
# mc-leaner: launchd hygiene module
# Purpose: Heuristically identify orphaned LaunchAgents and LaunchDaemons and optionally relocate their plists to backups
# Safety: Defaults to dry-run; never deletes; moves require explicit `--apply` and per-item confirmation; hard-skips security software

set -euo pipefail

# ----------------------------
# Defensive: ensure explain_log exists (modules should not assume it)
# ----------------------------
if ! type explain_log >/dev/null 2>&1; then
  explain_log() {
    # Purpose: best-effort verbose logging when --explain is enabled
    # Safety: Logging only; does not change behavior
    if [[ "${EXPLAIN:-false}" == "true" ]]; then
      log "$@"
    fi
  }
fi

# ----------------------------
# Module entry point
# ----------------------------
run_launchd_module() {
  local mode="$1" apply="$2" backup_dir="$3"
  local inventory_index_file="$4"
  local flagged_count=0
  local flagged_items=()
  local move_fail_count=0
  local move_failures=()

  # ----------------------------
  # Summary: module end-of-run contract
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
  # Helper: resolve launchd program path from a plist
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
  # Inventory-based installed checks
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
    [[ -n "$k" && -f "$inventory_index_file" ]] || return 1
    awk -F$'\t' -v k="$k" '$1==k {found=1; exit} END{exit (found?0:1)}' "$inventory_index_file" 2>/dev/null
  }

  _inventory_index_has_path() {
    # Purpose: check if inventory index contains an exact path in column 4
    local p="$1"
    [[ -n "$p" && -f "$inventory_index_file" ]] || return 1
    awk -F$'\t' -v p="$p" '$4==p {found=1; exit} END{exit (found?0:1)}' "$inventory_index_file" 2>/dev/null
  }

  _launchd_label_matches_inventory() {
    # Purpose: reduce false positives by skipping launchd labels that map to installed software
    # Strategy (conservative):
    #  - exact key match against inventory index (bundle id or normalized name keys)
    #  - normalized last component match (common for labels like com.vendor.app.helper)
    local label="$1"

    # If inventory is not available, do not claim a match.
    [[ -n "$label" && -f "$inventory_index_file" ]] || return 1

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
  # Snapshot active launchctl jobs
  # ----------------------------
  log "Scanning active launchctl jobs..."
  local active_jobs_file
  active_jobs_file="$(tmpfile)"

  # Helper: determine whether a label is currently loaded (reduces false positives)
  launchctl list | awk 'NR>1 {print $3}' | grep -v '^-$' >"$active_jobs_file" 2>/dev/null || true

  is_active_job() {
    local job="$1"
    grep -qxF "$job" "$active_jobs_file"
  }

  # ----------------------------
  # Launchd scan targets
  # ----------------------------
  log "Checking LaunchAgents/LaunchDaemons..."
  local paths=(
    "/Library/LaunchAgents"
    "/Library/LaunchDaemons"
    "$HOME/Library/LaunchAgents"
    "$HOME/Library/LaunchDaemons"
  )

  # ----------------------------
  # Heuristic scan
  # ----------------------------
  local checked=0
  local orphan_found=0
  for dir in "${paths[@]}"; do
    [[ -d "$dir" ]] || continue
    for plist_path in "$dir"/*.plist; do
      [[ -f "$plist_path" ]] || continue

      local label
      label="$(defaults read "$plist_path" Label 2>/dev/null || true)"
      [[ -n "${label:-}" ]] || continue

      checked=$((checked + 1))

      # HARD SAFETY: never touch security or endpoint protection software
      if is_protected_label "$label"; then
        log "SKIP (protected): $plist_path"
        explain_log "  reason: label protected (${label})"
        continue
      fi

      # Skip Homebrew-managed services (users should manage these via Homebrew)
      if is_homebrew_service_label "$label"; then
        log "SKIP (homebrew service): $plist_path"
        explain_log "  reason: homebrew-managed label (${label})"
        continue
      fi

      # Skip active services to avoid disrupting running processes
      if is_active_job "$label"; then
        explain_log "SKIP (active job): $plist_path (label: $label)"
        continue
      fi

      # Skip labels that match installed software via inventory index (preferred)
      if _launchd_label_matches_inventory "$label"; then
        explain_log "SKIP (installed-match via inventory): $plist_path (label: $label)"
        continue
      fi

      # Back-compat: if a legacy known-apps file is provided and readable, use it as an additional skip-list.
      # (Do not require it; inventory should be the primary source of truth.)
      if [[ -n "${inventory_index_file:-}" && -f "${inventory_index_file}" ]]; then
        : # inventory present; nothing else to do here
      fi

      local prog
      prog="$(_launchd_program_path "$plist_path")"

      # If we cannot resolve a program path, skip instead of guessing.
      # This prevents false positives for plists that only define other keys.
      if [[ -z "$prog" ]]; then
        log "SKIP (unknown program): $plist_path (label: $label, program: <none>)"
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

      # NOTE: only plists with a missing program path are treated as orphans; confirmation is still required
      # SAFETY: only move items when explicitly running in clean mode with --apply
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

  _launchd_summary_emit "${checked}"
}

# End of module
