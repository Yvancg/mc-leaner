#!/bin/bash
# mc-leaner: CLI entry point
# Purpose: Parse arguments, assemble system context, and dispatch selected modules
# Safety: Defaults to dry-run; any file moves require explicit `--apply`; no deletions

# NOTE: Scripts run with strict mode for deterministic failures and auditability.
set -euo pipefail

# Suppress SIGPIPE noise when output is piped to a consumer that exits early (e.g., `head -n`, `rg -m`).
# Safety: output ergonomics only; does not affect inspection results.
trap '' PIPE

# ----------------------------
# Bootstrap
# ----------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------
# Load shared libraries and modules
# ----------------------------
# shellcheck source=lib/*.sh
source "$ROOT_DIR/lib/utils.sh"

# Logging contract:
# - stdout is reserved for machine-readable records
# - human logs go to stderr
# `lib/utils.sh` is the single source of truth for ts/log helpers.

# Defensive fallbacks when running in partial environments.
# `lib/utils.sh` is the primary source of truth; these only exist if utils is missing/incomplete.
if ! declare -F log >/dev/null 2>&1; then
  ts() { /bin/date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || /bin/date; }
  log() { { printf '[%s] %s\n' "$(ts)" "$*" >&2; } 2>/dev/null || true; }
  log_info()  { log "$@"; }
  log_warn()  { log "$@"; }
  log_error() { log "$@"; }
fi

# Initialize privacy/service counters once per run (v2.3.0 contract).
if declare -F privacy_reset_counters >/dev/null 2>&1; then
  privacy_reset_counters
fi
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

# Defensive: some helpers may use a scratch variable named `tmp`.
# Under `set -u`, reference to an unset variable is fatal, so initialize it.
# Modules should still use local tmp variables where appropriate.
tmp=""

known_apps_file=""            # legacy: mixed list used by launchd heuristics
brew_bins_file=""             # preferred: brew executable basenames list (from inventory when available)
installed_bundle_ids_file=""  # legacy: bundle id list used by leftovers module

ensure_inventory() {
  # Purpose: Build inventory once per invocation.
  # Contract: inventory.sh should export INVENTORY_READY/INVENTORY_FILE/INVENTORY_INDEX_FILE.
  # Usage: ensure_inventory [inventory_mode]
  #   - scan (default): apps + Homebrew
  #   - brew-only: Homebrew-only inventory (skip app scans)
  local inv_mode="${1:-scan}"

  if [[ "$inventory_ready" == "true" ]]; then
    return 0
  fi

  # Best-effort; if inventory cannot be built, we keep going and let modules fall back.
  run_inventory_module "${inv_mode}" "false" "$BACKUP_DIR" "$EXPLAIN" || true

  inventory_ready="${INVENTORY_READY:-false}"
  inventory_file="${INVENTORY_FILE:-}"
  inventory_index_file="${INVENTORY_INDEX_FILE:-}"
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
  : > "${brew_bins_file}"

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

  known_apps_file="$(tmpfile)"
  : > "${known_apps_file}"

  if [[ "$inventory_ready" == "true" && -n "$inventory_file" && -f "$inventory_file" ]]; then
    # Apps: keep the legacy behavior for launchd heuristics (paths work well).
    awk -F'\t' '$1=="app"{print $5}' "$inventory_file" >> "$known_apps_file" 2>/dev/null || true

    # Homebrew: prefer inventory-exported lists to avoid extra brew calls.
    # Keys match inventory indexes: brew:formula:<name>, brew:cask:<name>.
    if [[ -n "${INVENTORY_BREW_FORMULAE:-}" ]]; then
      while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        printf 'brew:formula:%s\n' "${f}" >> "$known_apps_file" 2>/dev/null || true
      done <<< "$(printf '%s\n' "${INVENTORY_BREW_FORMULAE}" | awk 'NF' 2>/dev/null || true)"
    fi

    if [[ -n "${INVENTORY_BREW_CASKS:-}" ]]; then
      while IFS= read -r c; do
        [[ -n "${c}" ]] || continue
        printf 'brew:cask:%s\n' "${c}" >> "$known_apps_file" 2>/dev/null || true
      done <<< "$(printf '%s\n' "${INVENTORY_BREW_CASKS}" | awk 'NF' 2>/dev/null || true)"
    fi
  else
    # Fallback: inventory not available; best-effort brew queries.
    if is_cmd brew; then
      brew list --formula 2>/dev/null | awk 'NF{print "brew:formula:"$0}' >> "$known_apps_file" 2>/dev/null || true
      brew list --cask    2>/dev/null | awk 'NF{print "brew:cask:"$0}'    >> "$known_apps_file" 2>/dev/null || true
    fi
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
  : > "${installed_bundle_ids_file}"

  if [[ "$inventory_ready" == "true" && -n "$inventory_file" && -f "$inventory_file" ]]; then
    awk -F'\t' '$1=="app" && $4!="" && $4!="-"{print $4}' "$inventory_file" \
      | sort -u >> "$installed_bundle_ids_file" 2>/dev/null || true
    return 0
  fi

  # Fallback: scan /Applications and ~/Applications and read Info.plist
  local apps_file
  apps_file="$(tmpfile)"
  find /Applications -maxdepth 2 -type d -name "*.app" > "${apps_file}" 2>/dev/null || true
  find "$HOME/Applications" -maxdepth 2 -type d -name "*.app" >> "${apps_file}" 2>/dev/null || true

  while IFS= read -r app; do
    [[ -d "$app" ]] || continue
    local plist="$app/Contents/Info.plist"
    [[ -f "$plist" ]] || continue
    local bid
    bid="$(/usr/bin/defaults read "$plist" CFBundleIdentifier 2>/dev/null || true)"
    [[ -n "$bid" ]] && { printf '%s\n' "$bid" >> "$installed_bundle_ids_file"; }
  done < "${apps_file}"

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
  /bin/date +%s 2>/dev/null || printf '0\n'
}

_elapsed_s() {
  local start_s="${1:-0}"
  local end_s
  end_s="$(_now_epoch_s)"

  if [[ -z "$start_s" || ! "$start_s" =~ ^[0-9]+$ ]]; then
    printf '0\n'
    return 0
  fi
  if [[ -z "$end_s" || ! "$end_s" =~ ^[0-9]+$ ]]; then
    printf '0\n'
    return 0
  fi

  printf '%s\n' $(( end_s - start_s ))
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

# ----------------------------
# Insights (v2.3.0)
# ----------------------------
# Purpose: correlate already-flagged disk consumers with persistent background services.
# Safety: logging only; no new scans; no recommendations.

_insight_log() {
  log "INSIGHT: $*"
}

_summary_mb_to_human() {
  # Usage: _summary_mb_to_human <mb_int>
  # Purpose: Small helper for insight lines (human-readable size from MB).
  # Output: e.g. "519MB" or "1.6GB"
  local mb_raw="${1:-0}"

  if [[ -z "$mb_raw" || ! "$mb_raw" =~ ^[0-9]+$ ]]; then
    printf '0MB'
    return 0
  fi

  if (( mb_raw >= 1024 )); then
    # One decimal place for GB.
    /usr/bin/awk -v mb="$mb_raw" 'BEGIN{printf "%.1fGB", mb/1024.0}'
    return 0
  fi

  printf '%sMB' "${mb_raw}"
}

_extract_service_owner_persistence_map() {
  # Input: SERVICE_RECORDS_LIST (lines: scope=... | persistence=... | owner=... | label=...)
  # Output: lines "owner\tpersistence" (may include duplicates)
  local line owner persistence

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue

    owner="$(printf '%s' "$line" | sed -n 's/.*| owner=\([^|]*\) |.*/\1/p' | sed 's/^ *//;s/ *$//')"
    persistence="$(printf '%s' "$line" | sed -n 's/.*persistence=\([^|]*\) |.*/\1/p' | sed 's/^ *//;s/ *$//')"

    [[ -n "$owner" && -n "$persistence" ]] || continue

    # Correlation insights are persistence-backed: only boot/login (exclude on-demand).
    if [[ "$persistence" == "on-demand" ]]; then
      continue
    fi

    printf '%s\t%s\n' "$owner" "$persistence"
  done <<<"${SERVICE_RECORDS_LIST:-}"
}

_emit_disk_service_insights() {
  # Purpose: emit one-line insights when a flagged disk owner also appears as a persistent service owner.
  # Constraints:
  # - Only flagged disk items (DISK_FLAGGED_RECORDS_LIST)
  # - Only inventory-backed owners (skip Unknown)
  # - One persistence per owner (prefer boot over login)
  local svc_map owner persistence size_h
  local seen_owners
  seen_owners=$'\n'

  [[ -n "${DISK_FLAGGED_RECORDS_LIST:-}" ]] || return 0
  [[ -n "${SERVICE_RECORDS_LIST:-}" ]] || return 0

  # Prefer boot over login when multiple persistence values exist for the same owner.
  svc_map="$(_extract_service_owner_persistence_map | /usr/bin/awk -F '\t' '
    function rank(p){return (p=="boot"?2:(p=="login"?1:0))}
    {
      r=rank($2)
      if (!($1 in best) || r>best[$1]) {best[$1]=r; val[$1]=$2}
    }
    END{for (k in val) print k"\t"val[k]}
  ')"
  [[ -n "$svc_map" ]] || return 0

  while IFS=$'\t' read -r owner mb path; do
    [[ -n "${owner}" && -n "${path}" ]] || continue
    [[ "${owner}" != "Unknown" ]] || continue
    # Dedupe insights by owner (Bash 3.2-safe; no associative arrays).
    if [[ "$seen_owners" == *$'\n'"${owner}"$'\n'* ]]; then
      continue
    fi
    seen_owners+="${owner}"$'\n'

    persistence="$(printf '%s\n' "$svc_map" | /usr/bin/awk -F '\t' -v o="$owner" '$1==o{print $2; exit}')"
    [[ -n "$persistence" ]] || continue

    size_h="$(_summary_mb_to_human "${mb:-0}")"

    _insight_log "${owner} uses ${size_h} and runs at ${persistence}"
  done <<<"${DISK_FLAGGED_RECORDS_LIST}"
}

run_started_s="$(_now_epoch_s)"

# ----------------------------
# Phase helpers (dedupe scan/clean dispatch)
# ----------------------------
# Contract: these helpers must not change behavior; they only parameterize existing calls.

_run_brew_phase() {
  # Usage: _run_brew_phase [inventory_mode]
  # NOTE: brew module is inspection-first; keep behavior stable and explicit.
  local inv_mode="${1:-scan}"

  ensure_inventory "${inv_mode}"

  # Contract: run_brew_module <mode> <apply> <backup_dir> <explain> [inventory_index_file]
  run_brew_module "brew-only" "false" "$BACKUP_DIR" "$EXPLAIN" "${inventory_index_file:-}"
  summary_add "brew: inspected"
}

_run_launchd_phase() {
  # Usage: _run_launchd_phase <phase_mode> <apply_bool>
  local phase_mode="${1:-scan}"
  local apply_bool="${2:-false}"

  ensure_inventory
  ensure_known_apps

  local run_mode="scan"
  local run_apply="false"
  local summary_verb="inspected"

  if [[ "${phase_mode}" != "scan" || "${apply_bool}" == "true" ]]; then
    run_mode="clean"
    run_apply="true"
    summary_verb="cleaned"
  fi

  run_launchd_module "${run_mode}" "${run_apply}" "$BACKUP_DIR" "${inventory_index_file:-}" "${known_apps_file:-}"
  summary_add "launchd: ${summary_verb} (flagged=${LAUNCHD_FLAGGED_COUNT:-0})"

  if [[ "${LAUNCHD_FLAGGED_COUNT:-0}" -gt 0 && -n "${LAUNCHD_FLAGGED_IDS_LIST:-}" ]]; then
    _summary_add_list "launchd" "${LAUNCHD_FLAGGED_IDS_LIST}" 50
  fi
}

_run_bins_phase() {
  # Usage: _run_bins_phase <phase_mode> <apply_bool>
  local phase_mode="${1:-scan}"
  local apply_bool="${2:-false}"

  ensure_inventory
  ensure_brew_bins

  local run_mode="scan"
  local run_apply="false"
  local summary_verb="inspected"

  if [[ "${phase_mode}" != "scan" || "${apply_bool}" == "true" ]]; then
    run_mode="clean"
    run_apply="true"
    summary_verb="cleaned"
  fi

  run_bins_module "${run_mode}" "${run_apply}" "$BACKUP_DIR" "${inventory_index_file:-}" "${brew_bins_file:-}"
  summary_add "bins: ${summary_verb}"
}

_run_caches_phase() {
  # Usage: _run_caches_phase <phase_mode> <apply_bool>
  local phase_mode="${1:-scan}"
  local apply_bool="${2:-false}"

  ensure_inventory

  local run_mode="scan"
  local run_apply="false"
  local summary_verb="inspected"

  if [[ "${phase_mode}" != "scan" || "${apply_bool}" == "true" ]]; then
    run_mode="clean"
    run_apply="true"
    summary_verb="cleaned"
  fi

  run_caches_module "${run_mode}" "${run_apply}" "$BACKUP_DIR" "$EXPLAIN" "${inventory_index_file:-}"
  summary_add "caches: ${summary_verb} (flagged=${CACHES_FLAGGED_COUNT:-0})"

  if [[ "${CACHES_FLAGGED_COUNT:-0}" -gt 0 && -n "${CACHES_FLAGGED_IDS_LIST:-}" ]]; then
    _summary_add_list "caches" "${CACHES_FLAGGED_IDS_LIST}" 50
  fi
}

_run_logs_phase() {
  # Usage: _run_logs_phase <apply_bool>
  local apply_bool="${1:-false}"

  if [[ "${apply_bool}" != "true" ]]; then
    run_logs_module "false" "$BACKUP_DIR" "$EXPLAIN" "50"
    summary_add "logs: inspected (flagged=${LOGS_FLAGGED_COUNT:-0} threshold=50MB)"
  else
    run_logs_module "true" "$BACKUP_DIR" "$EXPLAIN" "50"
    summary_add "logs: cleaned (flagged=${LOGS_FLAGGED_COUNT:-0} threshold=50MB)"
  fi

  if [[ "${LOGS_FLAGGED_COUNT:-0}" -gt 0 && -n "${LOGS_FLAGGED_IDS_LIST:-}" ]]; then
    _summary_add_list "logs" "${LOGS_FLAGGED_IDS_LIST}" 50
  fi
}

_run_permissions_phase() {
  # Usage: _run_permissions_phase <apply_bool>
  local apply_bool="${1:-false}"

  if [[ "${apply_bool}" != "true" ]]; then
    run_permissions_module "false" "$BACKUP_DIR" "$EXPLAIN"
    summary_add "permissions: inspected"
  else
    run_permissions_module "true" "$BACKUP_DIR" "$EXPLAIN"
    summary_add "permissions: cleaned"
  fi
}

_run_startup_phase() {
  # Usage: _run_startup_phase
  # NOTE: startup is inspection-only, always scan/false (even in clean/apply).
  ensure_inventory

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
}

_run_disk_phase() {
  # Usage: _run_disk_phase
  # NOTE: disk is inspection-only, always scan/false (even in clean/apply).
  ensure_inventory

  run_disk_module "scan" "false" "$BACKUP_DIR" "$EXPLAIN" "$inventory_index_file"
  summary_add "disk: inspected (flagged=${DISK_FLAGGED_COUNT:-0} total_mb=${DISK_TOTAL_MB:-0} printed=${DISK_PRINTED_COUNT:-0} threshold_mb=${DISK_THRESHOLD_MB:-0})"

  if [[ "${DISK_FLAGGED_COUNT:-0}" -gt 0 && -n "${DISK_FLAGGED_IDS_LIST:-}" ]]; then
    _summary_add_list "disk" "${DISK_FLAGGED_IDS_LIST}" 50
  fi
}

_run_leftovers_phase() {
  # Usage: _run_leftovers_phase <apply_bool>
  local apply_bool="${1:-false}"

  ensure_installed_bundle_ids

  if [[ "${apply_bool}" != "true" ]]; then
    run_leftovers_module "false" "$BACKUP_DIR" "$EXPLAIN" "$installed_bundle_ids_file"
    summary_add "leftovers: inspected (flagged=${LEFTOVERS_FLAGGED_COUNT:-0} threshold=50MB)"
  else
    run_leftovers_module "true" "$BACKUP_DIR" "$EXPLAIN" "$installed_bundle_ids_file"
    summary_add "leftovers: cleaned (flagged=${LEFTOVERS_FLAGGED_COUNT:-0} threshold=50MB)"
  fi

  if [[ "${LEFTOVERS_FLAGGED_COUNT:-0}" -gt 0 && -n "${LEFTOVERS_FLAGGED_IDS_LIST:-}" ]]; then
    _summary_add_list "leftovers" "${LEFTOVERS_FLAGGED_IDS_LIST}" 50
  fi
}

_run_intel_phase() {
  run_intel_report
  summary_add "intel: report written"
}

# ----------------------------
# Dispatch by mode
# ----------------------------
case "$MODE" in
  scan)
    ensure_inventory
    ensure_brew_bins

    _run_brew_phase
    _run_launchd_phase "scan" "false"
    _run_bins_phase "scan" "false"
    _run_caches_phase "scan" "false"
    _run_logs_phase "false"
    _run_permissions_phase "false"
    _run_startup_phase
    _run_disk_phase
    _run_leftovers_phase "false"
    _run_intel_phase
    ;;
  clean)
    if [[ "$APPLY" != "true" ]]; then
      log_error "Refusing to clean without --apply (safety default)"
      exit 1
    fi

    ensure_inventory
    ensure_brew_bins

    _run_launchd_phase "clean" "true"
    _run_bins_phase "clean" "true"
    _run_caches_phase "clean" "true"
    _run_logs_phase "true"
    _run_permissions_phase "true"
    _run_startup_phase
    _run_disk_phase
    _run_leftovers_phase "true"
    _run_intel_phase
    ;;
  leftovers-only)
    _run_leftovers_phase "$APPLY"
    ;;
  report)
    _run_intel_phase
    ;;
  launchd-only)
    _run_launchd_phase "$([[ "$APPLY" == "true" ]] && printf 'clean' || printf 'scan')" "$APPLY"
    ;;
  bins-only)
    _run_bins_phase "$([[ "$APPLY" == "true" ]] && printf 'clean' || printf 'scan')" "$APPLY"
    ;;
  caches-only)
    _run_caches_phase "$([[ "$APPLY" == "true" ]] && printf 'clean' || printf 'scan')" "$APPLY"
    ;;
  logs-only)
    _run_logs_phase "$APPLY"
    ;;
  permissions-only)
    _run_permissions_phase "$APPLY"
    ;;
  brew-only)
    _run_brew_phase "brew-only"
    ;;
  startup-only)
    _run_startup_phase
    ;;
  disk-only)
    _run_disk_phase
    ;;

  inventory-only)
    ensure_inventory "scan"
    summary_add "inventory: inspected (ready=${INVENTORY_READY:-false})"
    ;;

  *)
    log_error "Unknown mode: $MODE"
    usage >&2
    exit 1
    ;;
esac

# v2.3.0: cross-module correlation insights (scan-only outputs; logging only)
_emit_disk_service_insights

summary_add "timing: startup=${STARTUP_DUR_S:-0}s launchd=${LAUNCHD_DUR_S:-0}s bins=${BINS_DUR_S:-0}s brew=${BREW_DUR_S:-0}s caches=${CACHES_DUR_S:-0}s intel=${INTEL_DUR_S:-0}s inventory=${INVENTORY_DUR_S:-0}s logs=${LOGS_DUR_S:-0}s disk=${DISK_DUR_S:-0}s leftovers=${LEFTOVERS_DUR_S:-0}s permissions=${PERMISSIONS_DUR_S:-0}s total=$(_elapsed_s "$run_started_s")s"
summary_print
log "Done."

# End of run
