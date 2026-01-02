#!/bin/bash
# mc-leaner: CLI entry point
# Purpose: Parse arguments, assemble system context, and dispatch selected modules
# Safety: Defaults to dry-run; any file moves require explicit `--apply`; no deletions

set -euo pipefail

# ----------------------------
# Bootstrap
# ----------------------------

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

# ----------------------------
# Parse CLI arguments
# ----------------------------
parse_args "$@"

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

# ----------------------------
# Build known-app inventory for heuristic matching
# ----------------------------
installed_apps_file="$(tmpfile)"
brew_formulae_file="$(tmpfile)"
known_apps_file="$(tmpfile)"

log "Scanning installed .app bundles..."
find /Applications -maxdepth 2 -type d -name "*.app" > "$installed_apps_file" 2>/dev/null || true
find "$HOME/Applications" -maxdepth 2 -type d -name "*.app" >> "$installed_apps_file" 2>/dev/null || true

: > "$brew_formulae_file"
if is_cmd brew; then
  log "Listing Homebrew formulae and casks..."
  brew list --formula >> "$brew_formulae_file" 2>/dev/null || true
  brew list --cask    >> "$brew_formulae_file" 2>/dev/null || true
else
  log "Homebrew not found, skipping brew-based checks."
fi

cat "$installed_apps_file" "$brew_formulae_file" > "$known_apps_file" 2>/dev/null || true

# ----------------------------
# Dispatch by mode
# ----------------------------
case "$MODE" in
  scan)
    run_launchd_module "scan" "false" "$BACKUP_DIR" "$known_apps_file"
    run_bins_module "scan" "false" "$BACKUP_DIR" "$brew_formulae_file"
    run_intel_report
    ;;
  clean)
    if [[ "$APPLY" != "true" ]]; then
      echo "Refusing to clean without --apply (safety default)"
      exit 1
    fi
    run_launchd_module "clean" "true" "$BACKUP_DIR" "$known_apps_file"
    run_bins_module "clean" "true" "$BACKUP_DIR" "$brew_formulae_file"
    run_intel_report
    ;;
  report)
    run_intel_report
    ;;
  launchd-only)
    if [[ "$APPLY" != "true" ]]; then
      run_launchd_module "scan" "false" "$BACKUP_DIR" "$known_apps_file"
    else
      run_launchd_module "clean" "true" "$BACKUP_DIR" "$known_apps_file"
    fi
    ;;
  bins-only)
    if [[ "$APPLY" != "true" ]]; then
      run_bins_module "scan" "false" "$BACKUP_DIR" "$brew_formulae_file"
    else
      run_bins_module "clean" "true" "$BACKUP_DIR" "$brew_formulae_file"
    fi
    ;;
  *)
    echo "Unknown mode: $MODE"
    usage
    exit 1
    ;;
esac

log "Done."  # End of run
