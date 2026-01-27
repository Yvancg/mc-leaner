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
source "$ROOT_DIR/modules/disk.sh"

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

# ----------------------------
# Summary helpers
# ----------------------------
_now_epoch_s() { 
  /bin/date +%s; 
}

_elapsed_s() {
  local start_s="$1"
  local end_s
  end_s="$(_now_epoch_s)"
  if [[ -z "$start_s" ]]; then
    echo 0
    return 0
  fi
  echo $(( end_s - start_s ))
}

_summary_add_list() {
  # Usage: _summary_add_list <label> <newline_delimited_items> [max_items]
  # Prints a header line and then one item per summary line (clean, grep-friendly).
  local label="$1"
  local items_nl="${2:-}"
  local max_items="${3:-0}"

  [[ -n "$items_nl" ]] || return 0

  # Read items into an array (preserve spaces inside items).
  local -a _items
  while IFS= read -r _line; do
    [[ -n "${_line}" ]] && _items+=("${_line}")
  done <<< "$items_nl"

  local total="${#_items[@]}"
  [[ "$total" -gt 0 ]] || return 0

  summary_add "${label}: flagged_items (${total})"

  local i
  local limit="$total"
  if [[ "$max_items" =~ ^[0-9]+$ && "$max_items" -gt 0 && "$max_items" -lt "$total" ]]; then
    limit="$max_items"
  fi

  for ((i=0; i<limit; i++)); do
    summary_add "${label}:  - ${_items[$i]}"
  done

  if [[ "$limit" -lt "$total" ]]; then
    summary_add "${label}:  - ... plus $((total - limit)) more"
  fi
}

run_started_s="$(_now_epoch_s)"


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
    summary_add "launchd: inspected (flagged=${LAUNCHD_FLAGGED_COUNT:-0})"
    if [[ "${LAUNCHD_FLAGGED_COUNT:-0}" -gt 0 && -n "${LAUNCHD_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "launchd" "${LAUNCHD_FLAGGED_IDS_LIST}" 50
    fi

    run_bins_module "scan" "false" "$BACKUP_DIR" "$inventory_index_file" "$brew_bins_file"
    summary_add "bins: inspected"

    # Use inventory index to label cache owners more accurately.
    run_caches_module "scan" "false" "$BACKUP_DIR" "$EXPLAIN" "$inventory_index_file"
    summary_add "caches: inspected (flagged=${CACHES_FLAGGED_COUNT:-0})"
    if [[ "${CACHES_FLAGGED_COUNT:-0}" -gt 0 && -n "${CACHES_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "caches" "${CACHES_FLAGGED_IDS_LIST}" 50
    fi
    run_logs_module "false" "$BACKUP_DIR" "$EXPLAIN" "50"
    summary_add "logs: inspected (flagged=${LOGS_FLAGGED_COUNT:-0} threshold=50MB)"
    if [[ "${LOGS_FLAGGED_COUNT:-0}" -gt 0 && -n "${LOGS_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "logs" "${LOGS_FLAGGED_IDS_LIST}" 50
    fi
    run_permissions_module "false" "$BACKUP_DIR" "$EXPLAIN"
    summary_add "permissions: inspected"
    # Startup inspection (inspection-only; never modifies system state)
    # Startup module exports (best-effort): STARTUP_CHECKED_COUNT, STARTUP_FLAGGED_COUNT,
    # STARTUP_UNKNOWN_OWNER_COUNT, STARTUP_BOOT_FLAGGED_COUNT, STARTUP_LOGIN_FLAGGED_COUNT,
    # STARTUP_SURFACE_BREAKDOWN, STARTUP_THRESHOLD_MODE
    run_startup_module "scan" "false" "$BACKUP_DIR" "$EXPLAIN" "$inventory_index_file"
    summary_add "startup: inspected=${STARTUP_CHECKED_COUNT:-0} flagged=${STARTUP_FLAGGED_COUNT:-0}"
    summary_add "startup:   boot: flagged=${STARTUP_BOOT_FLAGGED_COUNT:-0}"
    summary_add "startup:   login: flagged=${STARTUP_LOGIN_FLAGGED_COUNT:-0}"
    summary_add "startup:   estimated_risk=${STARTUP_ESTIMATED_RISK:-low}"
    if [[ "${STARTUP_FLAGGED_COUNT:-0}" -gt 0 && -n "${STARTUP_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "startup" "${STARTUP_FLAGGED_IDS_LIST}"
    fi
    if [[ "${STARTUP_BOOT_FLAGGED_COUNT:-0}" -gt 0 ]]; then
      summary_add "risk: startup_items_may_slow_boot"
    fi
    # Disk usage attribution (inspection-only; never modifies system state)
    run_disk_module "scan" "false" "$BACKUP_DIR" "$EXPLAIN" "$inventory_index_file"
    summary_add "disk: inspected (flagged=${DISK_FLAGGED_COUNT:-0} total_mb=${DISK_TOTAL_MB:-0} printed=${DISK_PRINTED_COUNT:-0} threshold_mb=${DISK_THRESHOLD_MB:-0})"
    if [[ "${DISK_FLAGGED_COUNT:-0}" -gt 0 && -n "${DISK_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "disk" "${DISK_FLAGGED_IDS_LIST}" 50
    fi
    ensure_installed_bundle_ids
    run_leftovers_module "false" "$BACKUP_DIR" "$EXPLAIN" "$installed_bundle_ids_file"
    summary_add "leftovers: inspected (flagged=${LEFTOVERS_FLAGGED_COUNT:-0} threshold=50MB)"
    if [[ "${LEFTOVERS_FLAGGED_COUNT:-0}" -gt 0 && -n "${LEFTOVERS_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "leftovers" "${LEFTOVERS_FLAGGED_IDS_LIST}" 50
    fi
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
    summary_add "launchd: cleaned (flagged=${LAUNCHD_FLAGGED_COUNT:-0})"
    if [[ "${LAUNCHD_FLAGGED_COUNT:-0}" -gt 0 && -n "${LAUNCHD_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "launchd" "${LAUNCHD_FLAGGED_IDS_LIST}" 50
    fi

    run_bins_module "clean" "true" "$BACKUP_DIR" "$inventory_index_file" "$brew_bins_file"
    summary_add "bins: cleaned"

    run_caches_module "clean" "true" "$BACKUP_DIR" "$EXPLAIN" "$inventory_index_file"
    summary_add "caches: cleaned (flagged=${CACHES_FLAGGED_COUNT:-0})"
    if [[ "${CACHES_FLAGGED_COUNT:-0}" -gt 0 && -n "${CACHES_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "caches" "${CACHES_FLAGGED_IDS_LIST}" 50
    fi
    run_logs_module "true" "$BACKUP_DIR" "$EXPLAIN" "50"
    summary_add "logs: cleaned (flagged=${LOGS_FLAGGED_COUNT:-0} threshold=50MB)"
    if [[ "${LOGS_FLAGGED_COUNT:-0}" -gt 0 && -n "${LOGS_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "logs" "${LOGS_FLAGGED_IDS_LIST}" 50
    fi
    run_permissions_module "true" "$BACKUP_DIR" "$EXPLAIN"
    summary_add "permissions: cleaned"
    # Startup inspection (inspection-only; never modifies system state)
    # Startup module exports (best-effort): STARTUP_CHECKED_COUNT, STARTUP_FLAGGED_COUNT,
    # STARTUP_UNKNOWN_OWNER_COUNT, STARTUP_BOOT_FLAGGED_COUNT, STARTUP_LOGIN_FLAGGED_COUNT,
    # STARTUP_SURFACE_BREAKDOWN, STARTUP_THRESHOLD_MODE
    run_startup_module "scan" "false" "$BACKUP_DIR" "$EXPLAIN" "$inventory_index_file"
    summary_add "startup: inspected=${STARTUP_CHECKED_COUNT:-0} flagged=${STARTUP_FLAGGED_COUNT:-0}"
    summary_add "startup:   boot: flagged=${STARTUP_BOOT_FLAGGED_COUNT:-0}"
    summary_add "startup:   login: flagged=${STARTUP_LOGIN_FLAGGED_COUNT:-0}"
    summary_add "startup:   estimated_risk=${STARTUP_ESTIMATED_RISK:-low}"
    if [[ "${STARTUP_FLAGGED_COUNT:-0}" -gt 0 && -n "${STARTUP_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "startup" "${STARTUP_FLAGGED_IDS_LIST}"
    fi
    if [[ "${STARTUP_BOOT_FLAGGED_COUNT:-0}" -gt 0 ]]; then
      summary_add "risk: startup_items_may_slow_boot"
    fi
    # Disk usage attribution (inspection-only; never modifies system state)
    run_disk_module "scan" "false" "$BACKUP_DIR" "$EXPLAIN" "$inventory_index_file"
    summary_add "disk: inspected (flagged=${DISK_FLAGGED_COUNT:-0} total_mb=${DISK_TOTAL_MB:-0} printed=${DISK_PRINTED_COUNT:-0} threshold_mb=${DISK_THRESHOLD_MB:-0})"
    if [[ "${DISK_FLAGGED_COUNT:-0}" -gt 0 && -n "${DISK_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "disk" "${DISK_FLAGGED_IDS_LIST}" 50
    fi
    ensure_installed_bundle_ids
    run_leftovers_module "true" "$BACKUP_DIR" "$EXPLAIN" "$installed_bundle_ids_file"
    summary_add "leftovers: cleaned (flagged=${LEFTOVERS_FLAGGED_COUNT:-0} threshold=50MB)"
    if [[ "${LEFTOVERS_FLAGGED_COUNT:-0}" -gt 0 && -n "${LEFTOVERS_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "leftovers" "${LEFTOVERS_FLAGGED_IDS_LIST}" 50
    fi
    run_intel_report
    summary_add "intel: report written"
    ;;
  leftovers-only)
    ensure_installed_bundle_ids
    if [[ "$APPLY" != "true" ]]; then
      run_leftovers_module "false" "$BACKUP_DIR" "$EXPLAIN" "$installed_bundle_ids_file"
      summary_add "leftovers: inspected (flagged=${LEFTOVERS_FLAGGED_COUNT:-0} threshold=50MB)"
    else
      run_leftovers_module "true" "$BACKUP_DIR" "$EXPLAIN" "$installed_bundle_ids_file"
      summary_add "leftovers: cleaned (flagged=${LEFTOVERS_FLAGGED_COUNT:-0} threshold=50MB)"
    fi
    if [[ "${LEFTOVERS_FLAGGED_COUNT:-0}" -gt 0 && -n "${LEFTOVERS_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "leftovers" "${LEFTOVERS_FLAGGED_IDS_LIST}" 50
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
      summary_add "launchd: inspected (flagged=${LAUNCHD_FLAGGED_COUNT:-0})"
    else
      run_launchd_module "clean" "true" "$BACKUP_DIR" "$inventory_index_file" "$known_apps_file"
      summary_add "launchd: cleaned (flagged=${LAUNCHD_FLAGGED_COUNT:-0})"
    fi
    if [[ "${LAUNCHD_FLAGGED_COUNT:-0}" -gt 0 && -n "${LAUNCHD_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "launchd" "${LAUNCHD_FLAGGED_IDS_LIST}" 50
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
      run_caches_module "scan" "false" "$BACKUP_DIR" "$EXPLAIN" "$inventory_index_file"
      summary_add "caches: inspected (flagged=${CACHES_FLAGGED_COUNT:-0})"
    else
      ensure_inventory
      run_caches_module "clean" "true" "$BACKUP_DIR" "$EXPLAIN" "$inventory_index_file"
      summary_add "caches: cleaned (flagged=${CACHES_FLAGGED_COUNT:-0})"
    fi
    if [[ "${CACHES_FLAGGED_COUNT:-0}" -gt 0 && -n "${CACHES_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "caches" "${CACHES_FLAGGED_IDS_LIST}" 50
    fi
    ;;
  logs-only)
    if [[ "$APPLY" != "true" ]]; then
      run_logs_module "false" "$BACKUP_DIR" "$EXPLAIN" "50"
      summary_add "logs: inspected (flagged=${LOGS_FLAGGED_COUNT:-0} threshold=50MB)"
    else
      run_logs_module "true" "$BACKUP_DIR" "$EXPLAIN" "50"
      summary_add "logs: cleaned (flagged=${LOGS_FLAGGED_COUNT:-0} threshold=50MB)"
    fi
    if [[ "${LOGS_FLAGGED_COUNT:-0}" -gt 0 && -n "${LOGS_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "logs" "${LOGS_FLAGGED_IDS_LIST}" 50
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
    # Startup module exports (best-effort): STARTUP_CHECKED_COUNT, STARTUP_FLAGGED_COUNT,
    # STARTUP_UNKNOWN_OWNER_COUNT, STARTUP_BOOT_FLAGGED_COUNT, STARTUP_LOGIN_FLAGGED_COUNT,
    # STARTUP_SURFACE_BREAKDOWN, STARTUP_THRESHOLD_MODE
    run_startup_module "scan" "false" "$BACKUP_DIR" "$EXPLAIN" "$inventory_index_file"
    summary_add "startup: inspected=${STARTUP_CHECKED_COUNT:-0} flagged=${STARTUP_FLAGGED_COUNT:-0}"
    summary_add "startup:   boot: flagged=${STARTUP_BOOT_FLAGGED_COUNT:-0}"
    summary_add "startup:   login: flagged=${STARTUP_LOGIN_FLAGGED_COUNT:-0}"
    summary_add "startup:   estimated_risk=${STARTUP_ESTIMATED_RISK:-low}"
    if [[ "${STARTUP_FLAGGED_COUNT:-0}" -gt 0 && -n "${STARTUP_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "startup" "${STARTUP_FLAGGED_IDS_LIST}"
    fi
    if [[ "${STARTUP_BOOT_FLAGGED_COUNT:-0}" -gt 0 ]]; then
      summary_add "risk: startup_items_may_slow_boot"
    fi
    ;;
  disk-only)
    ensure_inventory
    run_disk_module "scan" "false" "$BACKUP_DIR" "$EXPLAIN" "$inventory_index_file"
    summary_add "disk: inspected (flagged=${DISK_FLAGGED_COUNT:-0} total_mb=${DISK_TOTAL_MB:-0} printed=${DISK_PRINTED_COUNT:-0} threshold_mb=${DISK_THRESHOLD_MB:-0})"
    if [[ "${DISK_FLAGGED_COUNT:-0}" -gt 0 && -n "${DISK_FLAGGED_IDS_LIST:-}" ]]; then
      _summary_add_list "disk" "${DISK_FLAGGED_IDS_LIST}" 50
    fi
    ;;
  *)
    echo "Unknown mode: $MODE"
    usage
    exit 1
    ;;
esac

summary_add "timing: startup=${STARTUP_DUR_S:-0}s launchd=${LAUNCHD_DUR_S:-0}s caches=${CACHES_DUR_S:-0}s logs=${LOGS_DUR_S:-0}s disk=${DISK_DUR_S:-0}s leftovers=${LEFTOVERS_DUR_S:-0}s total=$(_elapsed_s "$run_started_s")s"
summary_print
log "Done."  # End of run
