#!/bin/bash
# mc-leaner: CLI entry point
# Purpose: Parse arguments, assemble system context, and dispatch selected modules
# Safety: Defaults to dry-run; any file moves require explicit `--apply`; no deletions

set -euo pipefail

# ----------------------------
# Bootstrap
# ----------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------
# Load shared libraries and modules
# ----------------------------
# shellcheck source=lib/*.sh
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/cli.sh"
source "$ROOT_DIR/lib/ui.sh"
source "$ROOT_DIR/lib/fs.sh"
source "$ROOT_DIR/lib/safety.sh"

source "$ROOT_DIR/modules/launchd.sh"
source "$ROOT_DIR/modules/bins_usr_local.sh"
source "$ROOT_DIR/modules/intel.sh"
source "$ROOT_DIR/modules/caches.sh"
source "$ROOT_DIR/modules/logs.sh"

source "$ROOT_DIR/modules/brew.sh"
source "$ROOT_DIR/modules/leftovers.sh"


# ----------------------------
# Lazy context builders (avoid unnecessary work per mode)
# ----------------------------
installed_apps_file=""
brew_formulae_file=""
known_apps_file=""
installed_bundle_ids_file=""
ensure_installed_bundle_ids() {
  # Purpose: Build a newline list of CFBundleIdentifier values for installed .app bundles
  # Notes: Used by leftovers module; best-effort; only runs once per invocation
  if [[ -n "$installed_bundle_ids_file" ]]; then
    return 0
  fi

  ensure_installed_apps

  installed_bundle_ids_file="$(tmpfile)"
  : > "$installed_bundle_ids_file"

  # Extract bundle identifiers for each .app found. Best-effort and quiet.
  while IFS= read -r app; do
    [[ -d "$app" ]] || continue
    local plist="$app/Contents/Info.plist"
    [[ -f "$plist" ]] || continue

    # Prefer defaults read for macOS compatibility; silence errors.
    local bid
    bid="$(/usr/bin/defaults read "$plist" CFBundleIdentifier 2>/dev/null || true)"
    [[ -n "$bid" ]] && echo "$bid" >> "$installed_bundle_ids_file"
  done < "$installed_apps_file"

  # De-duplicate and normalize.
  sort -u "$installed_bundle_ids_file" -o "$installed_bundle_ids_file" 2>/dev/null || true
}

ensure_installed_apps() {
  # Purpose: Build a list of installed .app bundles for heuristic matching
  # Notes: Only runs once per invocation
  if [[ -n "$installed_apps_file" ]]; then
    return 0
  fi

  installed_apps_file="$(tmpfile)"
  log "Scanning installed .app bundles..."
  find /Applications -maxdepth 2 -type d -name "*.app" > "$installed_apps_file" 2>/dev/null || true
  find "$HOME/Applications" -maxdepth 2 -type d -name "*.app" >> "$installed_apps_file" 2>/dev/null || true
}

ensure_brew_formulae() {
  # Purpose: Build a list of Homebrew formulae + casks for heuristic matching
  # Notes: Only runs once per invocation
  if [[ -n "$brew_formulae_file" ]]; then
    return 0
  fi

  brew_formulae_file="$(tmpfile)"
  : > "$brew_formulae_file"

  if is_cmd brew; then
    log "Listing Homebrew formulae and casks..."
    brew list --formula >> "$brew_formulae_file" 2>/dev/null || true
    brew list --cask    >> "$brew_formulae_file" 2>/dev/null || true
  else
    log "Homebrew not found, skipping brew-based checks."
  fi
}

ensure_known_apps() {
  # Purpose: Combine installed apps + brew inventory into a single known-app list
  # Notes: Only runs once per invocation
  if [[ -n "$known_apps_file" ]]; then
    return 0
  fi

  ensure_installed_apps
  ensure_brew_formulae

  known_apps_file="$(tmpfile)"
  cat "$installed_apps_file" "$brew_formulae_file" > "$known_apps_file" 2>/dev/null || true
}

# ----------------------------
# Parse CLI arguments
# ----------------------------
parse_args "$@"

# ----------------------------
# Explain mode default (safe under set -u)
# ----------------------------
EXPLAIN="${EXPLAIN:-false}"

# ----------------------------
# Resolve backup directory
# ----------------------------
if [[ -z "${BACKUP_DIR:-}" ]]; then
  BACKUP_DIR="$HOME/Desktop/McLeaner_Backups_$(date +%Y%m%d_%H%M%S)"
fi

# ----------------------------
# Log resolved execution plan
# ----------------------------
log "Mode: $MODE"
log "Apply: $APPLY"
log "Backup: $BACKUP_DIR"
log "Backup note: used only when --apply causes moves (reversible)."

# ----------------------------
# Run summary (end-of-run)
# ----------------------------
# Notes:
# - Each module already prints its own flagged items inline.
# - We also collect a concise end-of-run summary so global runs are easier to review.
summary_add "mode=$MODE apply=$APPLY backup=$BACKUP_DIR"
if [[ "$EXPLAIN" == "true" ]]; then
  summary_add "explain=true"
fi

# ----------------------------
# Dispatch by mode
# ----------------------------
case "$MODE" in
  scan)
    ensure_known_apps
    ensure_brew_formulae
    run_brew_module "false" "$BACKUP_DIR" "$EXPLAIN"
    summary_add "brew: inspected"
    run_launchd_module "scan" "false" "$BACKUP_DIR" "$known_apps_file"
    summary_add "launchd: inspected"
    run_bins_module "scan" "false" "$BACKUP_DIR" "$brew_formulae_file"
    summary_add "bins: inspected"
    run_caches_module "scan" "false" "$BACKUP_DIR"
    summary_add "caches: inspected"
    run_logs_module "false" "$BACKUP_DIR" "$EXPLAIN" "50"
    summary_add "logs: inspected (threshold=50MB)"
    ensure_installed_bundle_ids
    run_leftovers_module "false" "$BACKUP_DIR" "$EXPLAIN" "$installed_bundle_ids_file"
    summary_add "leftovers: inspected (threshold=50MB)"
    run_intel_report
    summary_add "intel: report written"
    ;;
  clean)
    if [[ "$APPLY" != "true" ]]; then
      echo "Refusing to clean without --apply (safety default)"
      exit 1
    fi
    ensure_known_apps
    ensure_brew_formulae
    run_launchd_module "clean" "true" "$BACKUP_DIR" "$known_apps_file"
    summary_add "launchd: cleaned"
    run_bins_module "clean" "true" "$BACKUP_DIR" "$brew_formulae_file"
    summary_add "bins: cleaned"
    run_caches_module "clean" "true" "$BACKUP_DIR"
    summary_add "caches: cleaned"
    run_logs_module "true" "$BACKUP_DIR" "$EXPLAIN" "50"
    summary_add "logs: cleaned (threshold=50MB)"
    ensure_installed_bundle_ids
    run_leftovers_module "true" "$BACKUP_DIR" "$EXPLAIN" "$installed_bundle_ids_file"
    summary_add "leftovers: cleaned (threshold=50MB)"
    run_intel_report
    summary_add "intel: report written"
    ;;
  leftovers-only)
    ensure_installed_bundle_ids
    if [[ "$APPLY" != "true" ]]; then
      run_leftovers_module "false" "$BACKUP_DIR" "$EXPLAIN" "$installed_bundle_ids_file"
      summary_add "leftovers: inspected (threshold=50MB)"
    else
      run_leftovers_module "true" "$BACKUP_DIR" "$EXPLAIN" "$installed_bundle_ids_file"
      summary_add "leftovers: cleaned (threshold=50MB)"
    fi
    ;;
  report)
    run_intel_report
    summary_add "intel: report written"
    ;;
  launchd-only)
    ensure_known_apps
    if [[ "$APPLY" != "true" ]]; then
      run_launchd_module "scan" "false" "$BACKUP_DIR" "$known_apps_file"
      summary_add "launchd: inspected"
    else
      run_launchd_module "clean" "true" "$BACKUP_DIR" "$known_apps_file"
      summary_add "launchd: cleaned"
    fi
    ;;
  bins-only)
    ensure_brew_formulae
    if [[ "$APPLY" != "true" ]]; then
      run_bins_module "scan" "false" "$BACKUP_DIR" "$brew_formulae_file"
      summary_add "bins: inspected"
    else
      run_bins_module "clean" "true" "$BACKUP_DIR" "$brew_formulae_file"
      summary_add "bins: cleaned"
    fi
    ;;
  caches-only)
    if [[ "$APPLY" != "true" ]]; then
      run_caches_module "scan" "false" "$BACKUP_DIR"
      summary_add "caches: inspected"
    else
      run_caches_module "clean" "true" "$BACKUP_DIR"
      summary_add "caches: cleaned"
    fi
    ;;
  logs-only)
    if [[ "$APPLY" != "true" ]]; then
      run_logs_module "false" "$BACKUP_DIR" "$EXPLAIN" "50"
      summary_add "logs: inspected (threshold=50MB)"
    else
      run_logs_module "true" "$BACKUP_DIR" "$EXPLAIN" "50"
      summary_add "logs: cleaned (threshold=50MB)"
    fi
    ;;
  brew-only)
    run_brew_module "false" "$BACKUP_DIR" "$EXPLAIN"
    summary_add "brew: inspected"
    ;;
  *)
    echo "Unknown mode: $MODE"
    usage
    exit 1
    ;;
esac

summary_print
log "Done."  # End of run
