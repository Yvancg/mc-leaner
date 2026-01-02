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


# ----------------------------
# Lazy context builders (avoid unnecessary work per mode)
# ----------------------------
installed_apps_file=""
brew_formulae_file=""
known_apps_file=""

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
# Dispatch by mode
# ----------------------------
case "$MODE" in
  scan)
    ensure_known_apps
    ensure_brew_formulae
    run_launchd_module "scan" "false" "$BACKUP_DIR" "$known_apps_file"
    run_bins_module "scan" "false" "$BACKUP_DIR" "$brew_formulae_file"
    run_caches_module "scan" "false" "$BACKUP_DIR"
    run_intel_report
    ;;
  clean)
    if [[ "$APPLY" != "true" ]]; then
      echo "Refusing to clean without --apply (safety default)"
      exit 1
    fi
    ensure_known_apps
    ensure_brew_formulae
    run_launchd_module "clean" "true" "$BACKUP_DIR" "$known_apps_file"
    run_bins_module "clean" "true" "$BACKUP_DIR" "$brew_formulae_file"
    run_caches_module "clean" "true" "$BACKUP_DIR"
    run_intel_report
    ;;
  report)
    run_intel_report
    ;;
  launchd-only)
    ensure_known_apps
    if [[ "$APPLY" != "true" ]]; then
      run_launchd_module "scan" "false" "$BACKUP_DIR" "$known_apps_file"
    else
      run_launchd_module "clean" "true" "$BACKUP_DIR" "$known_apps_file"
    fi
    ;;
  bins-only)
    ensure_brew_formulae
    if [[ "$APPLY" != "true" ]]; then
      run_bins_module "scan" "false" "$BACKUP_DIR" "$brew_formulae_file"
    else
      run_bins_module "clean" "true" "$BACKUP_DIR" "$brew_formulae_file"
    fi
    ;;
  caches-only)
    if [[ "$APPLY" != "true" ]]; then
      run_caches_module "scan" "false" "$BACKUP_DIR"
    else
      run_caches_module "clean" "true" "$BACKUP_DIR"
    fi
    ;;
  *)
    echo "Unknown mode: $MODE"
    usage
    exit 1
    ;;
esac

log "Done."  # End of run
