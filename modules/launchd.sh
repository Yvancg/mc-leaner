#!/bin/bash
# mc-leaner: launchd hygiene module
# Purpose: Heuristically identify orphaned LaunchAgents and LaunchDaemons and optionally relocate their plists to backups
# Safety: Defaults to dry-run; never deletes; moves require explicit `--apply` and per-item confirmation; hard-skips security software

set -euo pipefail

# ----------------------------
# Module entry point
# ----------------------------
run_launchd_module() {
  local mode="$1" apply="$2" backup_dir="$3"
  local known_apps_file="$4"

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
  local found=0
  for dir in "${paths[@]}"; do
    [[ -d "$dir" ]] || continue
    for plist_path in "$dir"/*.plist; do
      [[ -f "$plist_path" ]] || continue

      local label
      label="$(defaults read "$plist_path" Label 2>/dev/null || true)"
      [[ -n "${label:-}" ]] || continue

      # HARD SAFETY: never touch security or endpoint protection software
      if is_protected_label "$label"; then
        log "SKIP (protected): $plist_path"
        continue
      fi

      # Skip Homebrew-managed services (users should manage these via Homebrew)
      if is_homebrew_service_label "$label"; then
        log "SKIP (homebrew service): $plist_path"
        continue
      fi

      # Skip active services to avoid disrupting running processes
      if is_active_job "$label"; then
        continue
      fi

      # Skip labels that match known installed apps or Homebrew packages (heuristic)
      if grep -qF "$label" "$known_apps_file" 2>/dev/null; then
        continue
      fi

      found=1
      log "ORPHAN? $plist_path (label: $label)"

      # SAFETY: only move items when explicitly running in clean mode with --apply
      if [[ "$mode" == "clean" && "$apply" == "true" ]]; then
        if ask_yes_no "Orphaned launch item detected:\n$plist_path\n\nMove to backup folder?"; then
          safe_move "$plist_path" "$backup_dir"
          log "Moved: $plist_path"
        fi
      fi
    done
  done

  if [[ "$found" -eq 0 ]]; then
    log "No orphaned launchd plists found (by heuristics)."
  fi
}

# End of module
