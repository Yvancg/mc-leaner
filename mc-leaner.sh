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

source "$ROOT_DIR/modules/inventory.sh"
source "$ROOT_DIR/modules/launchd.sh"
source "$ROOT_DIR/modules/bins_usr_local.sh"
source "$ROOT_DIR/modules/intel.sh"
source "$ROOT_DIR/modules/caches.sh"
source "$ROOT_DIR/modules/logs.sh"

source "$ROOT_DIR/modules/brew.sh"
source "$ROOT_DIR/modules/leftovers.sh"
source "$ROOT_DIR/modules/permissions.sh"

source "$ROOT_DIR/modules/startup.sh"

# ----------------------------
# Startup module function shim
# ----------------------------
# The startup module is newer and may export different entrypoint names.
# Standard contract is `run_startup_module`, but support older names too.
if ! declare -F run_startup_module >/dev/null 2>&1; then
  run_startup_module() {
    if declare -F run_startup >/dev/null 2>&1; then
      run_startup "$@"
      return $?
    fi
    if declare -F startup_module >/dev/null 2>&1; then
      startup_module "$@"
      return $?
    fi
    if declare -F startup_inspect >/dev/null 2>&1; then
      startup_inspect "$@"
      return $?
    fi

    log "Startup module not available: expected function run_startup_module (or fallback name) not found."
    return 127
  }
fi


# ----------------------------
# Inventory-backed context builders
# ----------------------------
# The inventory module builds a unified list of installed software (apps + Homebrew)
# and an index for fast lookups. Other modules can consume derived lists.

inventory_ready="false"
inventory_file=""
inventory_index_file=""

known_apps_file=""            # legacy: mixed list used by launchd heuristics
brew_formulae_file=""         # legacy: list of brew formulae/casks used by /usr/local/bin heuristics
brew_bins_file=""             # preferred: brew executable basenames list (from inventory when available)
installed_bundle_ids_file=""  # legacy: bundle id list used by leftovers module

ensure_inventory() {
  # Purpose: Build inventory once per invocation.
  # Contract: inventory.sh should export INVENTORY_READY/INVENTORY_FILE/INVENTORY_INDEX_FILE.
  if [[ "$inventory_ready" == "true" ]]; then
    return 0
  fi

  # Best-effort; if inventory cannot be built, we keep going and let modules fall back.
  run_inventory_module "scan" "false" "$BACKUP_DIR" "$EXPLAIN" || true

  inventory_ready="${INVENTORY_READY:-false}"
  inventory_file="${INVENTORY_FILE:-}"
  inventory_index_file="${INVENTORY_INDEX_FILE:-}"
}

ensure_brew_formulae() {
  # Purpose: Build a newline list of Homebrew formulae+casks (legacy input for bins module)
  if [[ -n "$brew_formulae_file" ]]; then
    return 0
  fi

  ensure_inventory
  brew_formulae_file="$(tmpfile)"
  : > "$brew_formulae_file"

  if [[ "$inventory_ready" == "true" && -n "$inventory_file" && -f "$inventory_file" ]]; then
    # inventory.tsv columns: type, source, name, bundle_id, path
    awk -F'\t' '$1=="brew"{print $3}' "$inventory_file" | sort -u >> "$brew_formulae_file" 2>/dev/null || true
  elif is_cmd brew; then
    # Fallback: direct brew listing
    log "Listing Homebrew formulae and casks..."
    brew list --formula >> "$brew_formulae_file" 2>/dev/null || true
    brew list --cask    >> "$brew_formulae_file" 2>/dev/null || true
  else
    log "Homebrew not found, skipping brew-based checks."
  fi
}

ensure_brew_bins() {
  # Purpose: Build a newline list of Homebrew executable basenames.
  # Preferred source: inventory exports INVENTORY_BREW_BINS_FILE (fast, already computed).
  # Fallback: list brew prefix bin/sbin.
  if [[ -n "$brew_bins_file" ]]; then
    return 0
  fi

  ensure_inventory

  if [[ "${INVENTORY_BREW_BINS_READY:-false}" == "true" && -n "${INVENTORY_BREW_BINS_FILE:-}" && -r "${INVENTORY_BREW_BINS_FILE:-}" ]]; then
    brew_bins_file="$INVENTORY_BREW_BINS_FILE"
    return 0
  fi

  brew_bins_file="$(tmpfile)"
  : > "$brew_bins_file"

  if is_cmd brew; then
    local bp
    bp="$(brew --prefix 2>/dev/null || true)"
    if [[ -n "$bp" ]]; then
      {
        find "$bp/bin"  -maxdepth 1 -type f -perm -111 -print 2>/dev/null || true
        find "$bp/sbin" -maxdepth 1 -type f -perm -111 -print 2>/dev/null || true
      } | awk -F'/' 'NF{print $NF}' | sort -u >> "$brew_bins_file" 2>/dev/null || true
    fi
  fi
}

ensure_known_apps() {
  # Purpose: Legacy mixed list used by launchd heuristics.
  # For apps, we prefer paths; for brew, we include names.
  if [[ -n "$known_apps_file" ]]; then
    return 0
  fi

  ensure_inventory
  ensure_brew_formulae

  known_apps_file="$(tmpfile)"
  : > "$known_apps_file"

  if [[ "$inventory_ready" == "true" && -n "$inventory_file" && -f "$inventory_file" ]]; then
    awk -F'\t' '$1=="app"{print $5}' "$inventory_file" >> "$known_apps_file" 2>/dev/null || true
    cat "$brew_formulae_file" >> "$known_apps_file" 2>/dev/null || true
  else
    # Minimal fallback: keep behavior predictable even if inventory failed
    cat "$brew_formulae_file" >> "$known_apps_file" 2>/dev/null || true
  fi

  sort -u "$known_apps_file" -o "$known_apps_file" 2>/dev/null || true
}

ensure_installed_bundle_ids() {
  # Purpose: Build newline list of CFBundleIdentifier values for installed .app bundles
  # Source: inventory file when available; fallback to previous best-effort behavior.
  if [[ -n "$installed_bundle_ids_file" ]]; then
    return 0
  fi

  ensure_inventory

  installed_bundle_ids_file="$(tmpfile)"
  : > "$installed_bundle_ids_file"

  if [[ "$inventory_ready" == "true" && -n "$inventory_file" && -f "$inventory_file" ]]; then
    awk -F'\t' '$1=="app" && $4!="" && $4!="-"{print $4}' "$inventory_file" \
      | sort -u >> "$installed_bundle_ids_file" 2>/dev/null || true
    return 0
  fi

  # Fallback: scan /Applications and ~/Applications and read Info.plist
  local apps_file
  apps_file="$(tmpfile)"
  find /Applications -maxdepth 2 -type d -name "*.app" > "$apps_file" 2>/dev/null || true
  find "$HOME/Applications" -maxdepth 2 -type d -name "*.app" >> "$apps_file" 2>/dev/null || true

  while IFS= read -r app; do
    [[ -d "$app" ]] || continue
    local plist="$app/Contents/Info.plist"
    [[ -f "$plist" ]] || continue
    local bid
    bid="$(/usr/bin/defaults read "$plist" CFBundleIdentifier 2>/dev/null || true)"
    [[ -n "$bid" ]] && echo "$bid" >> "$installed_bundle_ids_file"
  done < "$apps_file"

  sort -u "$installed_bundle_ids_file" -o "$installed_bundle_ids_file" 2>/dev/null || true
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
    ensure_inventory
    ensure_brew_bins

    run_brew_module "false" "$BACKUP_DIR" "$EXPLAIN"
    summary_add "brew: inspected"

    # Prefer inventory index lookups; keep known_apps_file as a legacy fallback input.
    ensure_known_apps
    run_launchd_module "scan" "false" "$BACKUP_DIR" "$inventory_index_file" "$known_apps_file"
    summary_add "launchd: inspected"

    # Prefer brew executable basenames and inventory index for /usr/local/bin ownership.
    run_bins_module "scan" "false" "$BACKUP_DIR" "$inventory_index_file" "$brew_bins_file"
    summary_add "bins: inspected"

    # Use inventory index to label cache owners more accurately.
    run_caches_module "scan" "false" "$BACKUP_DIR" "$inventory_index_file"
    summary_add "caches: inspected"
    run_logs_module "false" "$BACKUP_DIR" "$EXPLAIN" "50"
    summary_add "logs: inspected (threshold=50MB)"
    run_permissions_module "false" "$BACKUP_DIR" "$EXPLAIN"
    summary_add "permissions: inspected"
    # Startup inspection (inspection-only; never modifies system state)
    run_startup_module "scan" "false" "$BACKUP_DIR" "$EXPLAIN" "$inventory_index_file"
    summary_add "startup: inspected"
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
    ensure_inventory
    ensure_brew_bins

    ensure_known_apps
    run_launchd_module "clean" "true" "$BACKUP_DIR" "$inventory_index_file" "$known_apps_file"
    summary_add "launchd: cleaned"

    run_bins_module "clean" "true" "$BACKUP_DIR" "$inventory_index_file" "$brew_bins_file"
    summary_add "bins: cleaned"

    run_caches_module "clean" "true" "$BACKUP_DIR" "$inventory_index_file"
    summary_add "caches: cleaned"
    run_logs_module "true" "$BACKUP_DIR" "$EXPLAIN" "50"
    summary_add "logs: cleaned (threshold=50MB)"
    run_permissions_module "true" "$BACKUP_DIR" "$EXPLAIN"
    summary_add "permissions: cleaned"
    # Startup inspection (inspection-only; never modifies system state)
    run_startup_module "scan" "false" "$BACKUP_DIR" "$EXPLAIN" "$inventory_index_file"
    summary_add "startup: inspected"
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
    ensure_inventory
    ensure_known_apps
    if [[ "$APPLY" != "true" ]]; then
      run_launchd_module "scan" "false" "$BACKUP_DIR" "$inventory_index_file" "$known_apps_file"
      summary_add "launchd: inspected"
    else
      run_launchd_module "clean" "true" "$BACKUP_DIR" "$inventory_index_file" "$known_apps_file"
      summary_add "launchd: cleaned"
    fi
    ;;
  bins-only)
    ensure_inventory
    ensure_brew_bins
    if [[ "$APPLY" != "true" ]]; then
      run_bins_module "scan" "false" "$BACKUP_DIR" "$inventory_index_file" "$brew_bins_file"
      summary_add "bins: inspected"
    else
      run_bins_module "clean" "true" "$BACKUP_DIR" "$inventory_index_file" "$brew_bins_file"
      summary_add "bins: cleaned"
    fi
    ;;
  caches-only)
    if [[ "$APPLY" != "true" ]]; then
      ensure_inventory
      run_caches_module "scan" "false" "$BACKUP_DIR" "$inventory_index_file"
      summary_add "caches: inspected"
    else
      ensure_inventory
      run_caches_module "clean" "true" "$BACKUP_DIR" "$inventory_index_file"
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
  permissions-only)
    if [[ "$APPLY" != "true" ]]; then
      run_permissions_module "false" "$BACKUP_DIR" "$EXPLAIN"
      summary_add "permissions: inspected"
    else
      run_permissions_module "true" "$BACKUP_DIR" "$EXPLAIN"
      summary_add "permissions: cleaned"
    fi
    ;;
  brew-only)
    run_brew_module "false" "$BACKUP_DIR" "$EXPLAIN"
    summary_add "brew: inspected"
    ;;
  startup-only)
    ensure_inventory
    run_startup_module "scan" "false" "$BACKUP_DIR" "$EXPLAIN" "$inventory_index_file"
    summary_add "startup: inspected"
    ;;
  *)
    echo "Unknown mode: $MODE"
    usage
    exit 1
    ;;
esac

summary_print
log "Done."  # End of run
