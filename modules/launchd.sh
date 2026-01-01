#!/bin/bash
set -euo pipefail

run_launchd_module() {
  local mode="$1" apply="$2" backup_dir="$3"
  local known_apps_file="$4"

  log "Scanning active launchctl jobs..."
  local active_jobs_file
  active_jobs_file="$(tmpfile)"
  launchctl list | awk 'NR>1 {print $3}' | grep -v '^-$' >"$active_jobs_file" 2>/dev/null || true

  is_active_job() {
    local job="$1"
    grep -qxF "$job" "$active_jobs_file"
  }

  log "Checking LaunchAgents/LaunchDaemons..."
  local paths=(
    "/Library/LaunchAgents"
    "/Library/LaunchDaemons"
    "$HOME/Library/LaunchAgents"
    "$HOME/Library/LaunchDaemons"
  )

  local found=0
  for dir in "${paths[@]}"; do
    [[ -d "$dir" ]] || continue
    for plist_path in "$dir"/*.plist; do
      [[ -f "$plist_path" ]] || continue

      local label
      label="$(defaults read "$plist_path" Label 2>/dev/null || true)"
      [[ -n "${label:-}" ]] || continue

      # HARD SAFETY
      if is_protected_label "$label"; then
        log "SKIP (protected): $plist_path"
        continue
      fi

      # Skip Homebrew services by default
      if is_homebrew_service_label "$label"; then
        log "SKIP (homebrew service): $plist_path"
        continue
      fi

      # Skip if active in launchctl
      if is_active_job "$label"; then
        continue
      fi

      # Skip if label matches known apps/brew list (basic contains)
      if grep -qF "$label" "$known_apps_file" 2>/dev/null; then
        continue
      fi

      found=1
      log "ORPHAN? $plist_path (label: $label)"

      if [[ "$mode" == "clean" && "$apply" == "true" ]]; then
        if ask_yes_no "Orphaned launch item detected:\n$plist_path\n\nMove to backup folder?"; then
          safe_move "$plist_path" "$backup_dir"
          log "Moved: $plist_path"
        fi
      fi
    done
  done

  [[ "$found" -eq 0 ]] && log "No orphaned launchd plists found (by heuristics)."
}
