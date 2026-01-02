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
  local known_apps_file="$4"

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

      # Skip labels that match known installed apps or Homebrew packages (heuristic)
      if grep -qF "$label" "$known_apps_file" 2>/dev/null; then
        explain_log "SKIP (known app match): $plist_path (label: $label)"
        continue
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
      else
        explain_log "OK (program exists): $plist_path (label: $label, program: $prog)"
        continue
      fi

      # NOTE: only plists with a missing program path are treated as orphans; confirmation is still required
      # SAFETY: only move items when explicitly running in clean mode with --apply
      if [[ "$mode" == "clean" && "$apply" == "true" ]]; then
        if ask_yes_no "Orphaned launch item detected:\n$plist_path\n\nMove to backup folder?"; then
          safe_move "$plist_path" "$backup_dir"
          log "Moved: $plist_path"
        fi
      fi
    done
  done

  if [[ "$orphan_found" -eq 0 ]]; then
    log "Launchd: no orphaned plists found (by heuristics)."
  fi
  explain_log "Launchd: checked ${checked} plists."
}

# End of module
