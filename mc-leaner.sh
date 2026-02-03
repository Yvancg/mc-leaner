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

# ----------------------------
# Logging Contract
# ----------------------------
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
load_config_file
parse_args "$@"

# ----------------------------
# Backup management (early exit)
# ----------------------------
_expand_user_path() {
  local p="$1"
  if [[ "$p" == "~"* ]]; then
    p="${p/#\~/$HOME}"
  fi
  printf '%s' "$p"
}

list_backups() {
  local base="$HOME/Desktop"
  local pattern="McLeaner_Backups_"
  local -a found
  found=()

  if [[ -d "$base" ]]; then
    local d
    for d in "$base"/"${pattern}"*; do
      [[ -d "$d" ]] || continue
      found+=("$d")
    done
  fi

  log "Backups: found ${#found[@]} backup folder(s) under ${base}"
  if [[ "${#found[@]}" -gt 0 ]]; then
    local f
    for f in "${found[@]}"; do
      log "  - ${f}"
    done
  fi
}

verify_backup() {
  local backup_dir="$1"
  backup_dir="$(_expand_user_path "$backup_dir")"

  if [[ -z "$backup_dir" || ! -d "$backup_dir" ]]; then
    log_error "Verify: backup folder not found: ${backup_dir}"
    return "${EXIT_CONFIG:-3}"
  fi

  local manifest
  manifest="$(backup_manifest_path "$backup_dir")"
  if [[ -z "$manifest" || ! -f "$manifest" ]]; then
    log_error "Verify: manifest not found: ${manifest}"
    return "${EXIT_CONFIG:-3}"
  fi

  local manifest_format
  if declare -F backup_manifest_format_detect >/dev/null 2>&1; then
    manifest_format="$(backup_manifest_format_detect "$backup_dir" 2>/dev/null || true)"
  else
    manifest_format="legacy"
  fi
  [[ -n "$manifest_format" ]] || manifest_format="legacy"

  local checksum_status
  if declare -F backup_manifest_checksum_verify >/dev/null 2>&1; then
    backup_manifest_checksum_verify "$backup_dir" || checksum_status=$?
  else
    checksum_status=3
  fi

  local checksum_state="unknown"
  case "${checksum_status:-0}" in
    0) checksum_state="ok" ;;
    1) checksum_state="missing" ;;
    2) checksum_state="mismatch" ;;
    *) checksum_state="error" ;;
  esac

  local total=0
  local missing=0
  local line ts src_field dest_field decoded
  while IFS=$'\t' read -r ts src_field dest_field; do
    [[ -n "$src_field" && -n "$dest_field" ]] || continue
    [[ "$ts" == \#* ]] && continue
    [[ "$ts" == \#* ]] && continue
    total=$((total + 1))
    if [[ "$manifest_format" == "v2" ]]; then
      decoded="$(printf '%s' "$dest_field" | /usr/bin/base64 -D 2>/dev/null || true)"
    else
      decoded="$dest_field"
    fi
    if [[ -z "$decoded" || ! -e "$decoded" ]]; then
      missing=$((missing + 1))
    fi
  done < "$manifest"

  log "Verify: backup_dir=${backup_dir}"
  log "Verify: manifest=${manifest}"
  log "Verify: format=${manifest_format}"
  log "Verify: checksum=${checksum_state}"
  log "Verify: entries=${total} missing_in_backup=${missing}"

  case "${checksum_state}" in
    ok)
      return "${EXIT_OK:-0}"
      ;;
    missing|mismatch)
      return "${EXIT_SAFETY:-5}"
      ;;
    *)
      return "${EXIT_IO:-4}"
      ;;
  esac
}

restore_backup() {
  local backup_dir="$1"
  backup_dir="$(_expand_user_path "$backup_dir")"

  _decode_b64_path() {
    local v="$1"
    local out
    out="$(printf '%s' "$v" | /usr/bin/base64 -D 2>/dev/null || true)"
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
    return 0
  }

  if [[ -z "$backup_dir" || ! -d "$backup_dir" ]]; then
    log_error "Restore: backup folder not found: ${backup_dir}"
    return "${EXIT_CONFIG:-3}"
  fi

  local manifest
  manifest="$(backup_manifest_path "$backup_dir")"
  if [[ -z "$manifest" || ! -f "$manifest" ]]; then
    log_error "Restore: manifest not found: ${manifest}"
    return "${EXIT_CONFIG:-3}"
  fi

  local manifest_format
  if declare -F backup_manifest_format_detect >/dev/null 2>&1; then
    manifest_format="$(backup_manifest_format_detect "$backup_dir" 2>/dev/null || true)"
  else
    manifest_format="legacy"
  fi
  [[ -n "$manifest_format" ]] || manifest_format="legacy"

  local checksum_status
  if declare -F backup_manifest_checksum_verify >/dev/null 2>&1; then
    backup_manifest_checksum_verify "$backup_dir" || checksum_status=$?
  else
    checksum_status=3
  fi

  case "${checksum_status:-0}" in
    0)
      :
      ;;
    1)
      if [[ "$manifest_format" == "legacy" ]]; then
        log_warn "Restore: legacy manifest detected (no checksum)"
        if ! ask_yes_no "Proceed with legacy restore (no checksum validation)?"; then
          return "${EXIT_SAFETY:-5}"
        fi
      else
        log_error "Restore: checksum missing (manifest cannot be verified)"
        return "${EXIT_SAFETY:-5}"
      fi
      ;;
    2)
      log_error "Restore: checksum mismatch (manifest may be tampered)"
      return "${EXIT_SAFETY:-5}"
      ;;
    *)
      log_error "Restore: checksum verification failed"
      return "${EXIT_IO:-4}"
      ;;
  esac

  log "Restore: using backup folder: ${backup_dir}"
  log "Restore: manifest: ${manifest}"

  local backup_dir_real
  backup_dir_real="$(cd "$backup_dir" 2>/dev/null && pwd -P)"
  [[ -n "$backup_dir_real" ]] || backup_dir_real="$backup_dir"

  local restored=0
  local skipped=0
  local failed=0

  while IFS=$'\t' read -r ts src_field dest_field; do
    [[ -n "$src_field" && -n "$dest_field" ]] || continue

    local src dest
    if [[ "$manifest_format" == "legacy" ]]; then
      src="$src_field"
      dest="$dest_field"
    else
      src="$(_decode_b64_path "$src_field" 2>/dev/null || true)"
      dest="$(_decode_b64_path "$dest_field" 2>/dev/null || true)"
    fi
    [[ -n "$src" && -n "$dest" ]] || continue

    local dest_real
    dest_real="$dest"
    if declare -F fs_resolve_symlink_target_physical >/dev/null 2>&1; then
      dest_real="$(fs_resolve_symlink_target_physical "$dest" 2>/dev/null || true)"
      [[ -n "$dest_real" ]] || dest_real="$dest"
    fi

    case "$dest_real" in
      "$backup_dir_real"/*) : ;;
      *)
        log "Restore: skip (outside backup dir): ${dest}"
        skipped=$((skipped + 1))
        continue
        ;;
    esac

    if [[ ! -e "$dest" ]]; then
      log "Restore: skip (missing in backup): ${dest}"
      skipped=$((skipped + 1))
      continue
    fi

    if [[ -e "$src" ]]; then
      log "Restore: skip (target exists): ${src}"
      skipped=$((skipped + 1))
      continue
    fi

    if ask_yes_no "Restore this item?\n${src}\n<-${dest}"; then
      local restore_out
      if restore_out="$(safe_restore "$dest" "$src" 2>&1)"; then
        log "Restored: ${dest} -> ${restore_out}"
        restored=$((restored + 1))
      else
        log "Restore failed: ${dest} | ${restore_out}"
        failed=$((failed + 1))
      fi
    else
      skipped=$((skipped + 1))
    fi
  done < "$manifest"

  log "Restore: completed restored=${restored} skipped=${skipped} failed=${failed}"
  if [[ "${failed}" -gt 0 ]]; then
    return "${EXIT_PARTIAL:-6}"
  fi
  return "${EXIT_OK:-0}"
}

if [[ "${LIST_BACKUPS:-false}" == "true" ]]; then
  list_backups
  exit "${EXIT_OK:-0}"
fi

if [[ -n "${RESTORE_BACKUP_DIR:-}" ]]; then
  restore_backup "${RESTORE_BACKUP_DIR}"
  exit $?
fi

if [[ -n "${VERIFY_BACKUP_DIR:-}" ]]; then
  verify_backup "${VERIFY_BACKUP_DIR}"
  exit $?
fi

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
# Report export (optional)
# ----------------------------
EXPORT_FILE="${EXPORT_FILE:-}"
if [[ -n "${EXPORT_FILE}" ]]; then
  if [[ "${EXPORT_FILE}" == "~"* ]]; then
    EXPORT_FILE="${EXPORT_FILE/#\~/$HOME}"
  fi
  export_dir="$(dirname "${EXPORT_FILE}")"
  if [[ -z "${export_dir}" ]]; then
    log_error "Export: invalid path: ${EXPORT_FILE}"
    exit "${EXIT_IO:-4}"
  fi
  mkdir -p "${export_dir}" 2>/dev/null || true
  if [[ ! -d "${export_dir}" ]]; then
    log_error "Export: cannot create directory: ${export_dir}"
    exit "${EXIT_IO:-4}"
  fi
  : > "${EXPORT_FILE}" 2>/dev/null || { log_error "Export: cannot write to ${EXPORT_FILE}"; exit "${EXIT_IO:-4}"; }
  exec 2> >(tee -a "${EXPORT_FILE}" >&2)
fi

# ----------------------------
# JSON file output (optional)
# ----------------------------
JSON_FILE="${JSON_FILE:-}"
if [[ -n "${JSON_FILE}" ]]; then
  if [[ "${JSON_FILE}" == "~"* ]]; then
    JSON_FILE="${JSON_FILE/#\~/$HOME}"
  fi
  json_dir="$(dirname "${JSON_FILE}")"
  if [[ -z "${json_dir}" ]]; then
    log_error "JSON: invalid path: ${JSON_FILE}"
    exit "${EXIT_IO:-4}"
  fi
  mkdir -p "${json_dir}" 2>/dev/null || true
  if [[ ! -d "${json_dir}" ]]; then
    log_error "JSON: cannot create directory: ${json_dir}"
    exit "${EXIT_IO:-4}"
  fi
  : > "${JSON_FILE}" 2>/dev/null || { log_error "JSON: cannot write to ${JSON_FILE}"; exit "${EXIT_IO:-4}"; }
fi

# ----------------------------
# Log resolved execution plan
# ----------------------------
log "Mode: $MODE"
log "Apply: $APPLY"
log "Backup: $BACKUP_DIR"
log "Backup note: used only when --apply causes moves (reversible)."
log "Allow sudo: ${ALLOW_SUDO:-false}"

# ----------------------------
# Progress indicator (optional)
# ----------------------------
PROGRESS="${PROGRESS:-false}"
PROGRESS_STEP=0
PROGRESS_TOTAL=1

progress_init() {
  local mode="$1"
  case "$mode" in
    scan) PROGRESS_TOTAL=10 ;;
    clean) PROGRESS_TOTAL=9 ;;
    report) PROGRESS_TOTAL=1 ;;
    inventory-only) PROGRESS_TOTAL=1 ;;
    launchd-only) PROGRESS_TOTAL=1 ;;
    startup-only) PROGRESS_TOTAL=1 ;;
    bins-only) PROGRESS_TOTAL=1 ;;
    caches-only) PROGRESS_TOTAL=1 ;;
    logs-only) PROGRESS_TOTAL=1 ;;
    brew-only) PROGRESS_TOTAL=1 ;;
    leftovers-only) PROGRESS_TOTAL=1 ;;
    permissions-only) PROGRESS_TOTAL=1 ;;
    disk-only) PROGRESS_TOTAL=1 ;;
    *) PROGRESS_TOTAL=1 ;;
  esac
}

progress_step() {
  local label="$1"
  [[ "${PROGRESS}" == "true" ]] || return 0
  PROGRESS_STEP=$((PROGRESS_STEP + 1))
  log "Progress: ${PROGRESS_STEP}/${PROGRESS_TOTAL} ${label}"
}

# ----------------------------
# JSON output mode (capture machine records)
# ----------------------------
JSON_OUTPUT="${JSON_OUTPUT:-false}"
JSON_STDOUT="${JSON_STDOUT:-false}"
JSON_RECORDS_FILE=""
if [[ "${JSON_OUTPUT}" == "true" ]]; then
  JSON_RECORDS_FILE="$(tmpfile_new "mcleaner.records")"
  if [[ -z "${JSON_RECORDS_FILE}" ]]; then
    log_error "JSON: failed to create temp records file"
    exit "${EXIT_IO:-4}"
  fi
  exec 3>&1
  exec 1>"${JSON_RECORDS_FILE}"
elif [[ -n "${EXPORT_FILE}" ]]; then
  # Include machine records in the exported report when JSON is not active.
  exec 1> >(tee -a "${EXPORT_FILE}")
fi

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
progress_init "$MODE"

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
}

_run_launchd_phase() {
  # Usage: _run_launchd_phase <phase_mode> <apply_bool>
  local phase_mode="${1:-scan}"
  local apply_bool="${2:-false}"

  ensure_inventory
  ensure_known_apps

  local run_mode="scan"
  local run_apply="false"
  if [[ "${phase_mode}" != "scan" || "${apply_bool}" == "true" ]]; then
    run_mode="clean"
    run_apply="true"
  fi

  run_launchd_module "${run_mode}" "${run_apply}" "$BACKUP_DIR" "${inventory_index_file:-}" "${known_apps_file:-}"

  if [[ "${LAUNCHD_FLAGGED_COUNT:-0}" -gt 0 && -n "${LAUNCHD_FLAGGED_IDS_LIST:-}" ]]; then
    summary_add_list "launchd" "${LAUNCHD_FLAGGED_IDS_LIST}" 50
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
  if [[ "${phase_mode}" != "scan" || "${apply_bool}" == "true" ]]; then
    run_mode="clean"
    run_apply="true"
  fi

  run_bins_module "${run_mode}" "${run_apply}" "$BACKUP_DIR" "$EXPLAIN" "${inventory_index_file:-}"
}

_run_caches_phase() {
  # Usage: _run_caches_phase <phase_mode> <apply_bool>
  local phase_mode="${1:-scan}"
  local apply_bool="${2:-false}"

  ensure_inventory

  local run_mode="scan"
  local run_apply="false"
  if [[ "${phase_mode}" != "scan" || "${apply_bool}" == "true" ]]; then
    run_mode="clean"
    run_apply="true"
  fi

  run_caches_module "${run_mode}" "${run_apply}" "$BACKUP_DIR" "$EXPLAIN" "${inventory_index_file:-}" "${THRESHOLD_CACHES_MB:-200}"

  if [[ "${CACHES_FLAGGED_COUNT:-0}" -gt 0 && -n "${CACHES_FLAGGED_IDS_LIST:-}" ]]; then
    summary_add_list "caches" "${CACHES_FLAGGED_IDS_LIST}" 50
  fi
}

_run_logs_phase() {
  # Usage: _run_logs_phase <apply_bool>
  local apply_bool="${1:-false}"

  if [[ "${apply_bool}" != "true" ]]; then
    run_logs_module "false" "$BACKUP_DIR" "$EXPLAIN" "${THRESHOLD_LOGS_MB:-50}"
  else
    run_logs_module "true" "$BACKUP_DIR" "$EXPLAIN" "${THRESHOLD_LOGS_MB:-50}"
  fi

  if [[ "${LOGS_FLAGGED_COUNT:-0}" -gt 0 && -n "${LOGS_FLAGGED_IDS_LIST:-}" ]]; then
    summary_add_list "logs" "${LOGS_FLAGGED_IDS_LIST}" 50
  fi
}

_run_permissions_phase() {
  # Usage: _run_permissions_phase <apply_bool>
  local apply_bool="${1:-false}"

  if [[ "${apply_bool}" != "true" ]]; then
    run_permissions_module "false" "$BACKUP_DIR" "$EXPLAIN"
  else
    run_permissions_module "true" "$BACKUP_DIR" "$EXPLAIN"
  fi
}

_run_startup_phase() {
  # Usage: _run_startup_phase
  # NOTE: startup is inspection-only, always scan/false (even in clean/apply).
  ensure_inventory

  run_startup_module "scan" "false" "$BACKUP_DIR" "$EXPLAIN" "$inventory_index_file"

  if [[ "${STARTUP_FLAGGED_COUNT:-0}" -gt 0 && -n "${STARTUP_FLAGGED_IDS_LIST:-}" ]]; then
    summary_add_list "startup" "${STARTUP_FLAGGED_IDS_LIST}"
  fi
  if [[ "${STARTUP_BOOT_FLAGGED_COUNT:-0}" -gt 0 ]]; then
    summary_add "risk startup_items_may_slow_boot=true"
  fi
}

_run_disk_phase() {
  # Usage: _run_disk_phase
  # NOTE: disk is inspection-only, always scan/false (even in clean/apply).
  ensure_inventory

  run_disk_module "scan" "false" "$BACKUP_DIR" "$EXPLAIN" "$inventory_index_file" "${THRESHOLD_DISK_MB:-200}"

  if [[ "${DISK_FLAGGED_COUNT:-0}" -gt 0 && -n "${DISK_FLAGGED_IDS_LIST:-}" ]]; then
    summary_add_list "disk" "${DISK_FLAGGED_IDS_LIST}" 50
  fi
}

_run_leftovers_phase() {
  # Usage: _run_leftovers_phase <apply_bool>
  local apply_bool="${1:-false}"

  ensure_installed_bundle_ids

  if [[ "${apply_bool}" != "true" ]]; then
    run_leftovers_module "false" "$BACKUP_DIR" "$EXPLAIN" "$installed_bundle_ids_file" "${inventory_index_file:-}" "${THRESHOLD_LEFTOVERS_MB:-50}"
  else
    run_leftovers_module "true" "$BACKUP_DIR" "$EXPLAIN" "$installed_bundle_ids_file" "${inventory_index_file:-}" "${THRESHOLD_LEFTOVERS_MB:-50}"
  fi

  if [[ "${LEFTOVERS_FLAGGED_COUNT:-0}" -gt 0 && -n "${LEFTOVERS_FLAGGED_IDS_LIST:-}" ]]; then
    summary_add_list "leftovers" "${LEFTOVERS_FLAGGED_IDS_LIST}" 50
  fi
}

_run_intel_phase() {
  run_intel_report
  summary_add "intel report_written=true"
}

# ----------------------------
# Dispatch by mode
# ----------------------------
case "$MODE" in
  scan)
    ensure_inventory
    ensure_brew_bins

    progress_step "brew"
    _run_brew_phase
    progress_step "launchd"
    _run_launchd_phase "scan" "false"
    progress_step "bins"
    _run_bins_phase "scan" "false"
    progress_step "caches"
    _run_caches_phase "scan" "false"
    progress_step "logs"
    _run_logs_phase "false"
    progress_step "permissions"
    _run_permissions_phase "false"
    progress_step "startup"
    _run_startup_phase
    progress_step "disk"
    _run_disk_phase
    progress_step "leftovers"
    _run_leftovers_phase "false"
    progress_step "intel"
    _run_intel_phase
    ;;
  clean)
    if [[ "$APPLY" != "true" ]]; then
      log_error "Refusing to clean without --apply (safety default)"
      exit "${EXIT_SAFETY:-5}"
    fi

    ensure_inventory
    ensure_brew_bins

    progress_step "launchd"
    _run_launchd_phase "clean" "true"
    progress_step "bins"
    _run_bins_phase "clean" "true"
    progress_step "caches"
    _run_caches_phase "clean" "true"
    progress_step "logs"
    _run_logs_phase "true"
    progress_step "permissions"
    _run_permissions_phase "true"
    progress_step "startup"
    _run_startup_phase
    progress_step "disk"
    _run_disk_phase
    progress_step "leftovers"
    _run_leftovers_phase "true"
    progress_step "intel"
    _run_intel_phase
    ;;
  leftovers-only)
    progress_step "leftovers"
    _run_leftovers_phase "$APPLY"
    ;;
  report)
    progress_step "intel"
    _run_intel_phase
    ;;
  launchd-only)
    progress_step "launchd"
    _run_launchd_phase "$([[ "$APPLY" == "true" ]] && printf 'clean' || printf 'scan')" "$APPLY"
    ;;
  bins-only)
    progress_step "bins"
    _run_bins_phase "$([[ "$APPLY" == "true" ]] && printf 'clean' || printf 'scan')" "$APPLY"
    ;;
  caches-only)
    progress_step "caches"
    _run_caches_phase "$([[ "$APPLY" == "true" ]] && printf 'clean' || printf 'scan')" "$APPLY"
    ;;
  logs-only)
    progress_step "logs"
    _run_logs_phase "$APPLY"
    ;;
  permissions-only)
    progress_step "permissions"
    _run_permissions_phase "$APPLY"
    ;;
  brew-only)
    progress_step "brew"
    _run_brew_phase "brew-only"
    ;;
  startup-only)
    progress_step "startup"
    _run_startup_phase
    ;;
  disk-only)
    progress_step "disk"
    _run_disk_phase
    ;;

  inventory-only)
    progress_step "inventory"
    ensure_inventory "scan"
    summary_add "inventory inspected=true ready=${INVENTORY_READY:-false}"
    ;;

  *)
    log_error "Unknown mode: $MODE"
    usage >&2
    exit "${EXIT_USAGE:-2}"
    ;;
esac

# v2.3.0: cross-module correlation insights (scan-only outputs; logging only)
_emit_disk_service_insights

summary_add "timing startup_s=${STARTUP_DUR_S:-0} launchd_s=${LAUNCHD_DUR_S:-0} bins_s=${BINS_DUR_S:-0} brew_s=${BREW_DUR_S:-0} caches_s=${CACHES_DUR_S:-0} intel_s=${INTEL_DUR_S:-0} inventory_s=${INVENTORY_DUR_S:-0} logs_s=${LOGS_DUR_S:-0} disk_s=${DISK_DUR_S:-0} leftovers_s=${LEFTOVERS_DUR_S:-0} permissions_s=${PERMISSIONS_DUR_S:-0} total_s=$(_elapsed_s "$run_started_s")"
summary_print
log "Done."

if [[ "${JSON_OUTPUT}" == "true" ]]; then
  exec 1>&3

  if [[ "${JSON_STDOUT}" == "true" ]]; then
    summary_emit_json "${JSON_RECORDS_FILE}"
  fi

  if [[ -n "${JSON_FILE}" ]]; then
    summary_emit_json "${JSON_RECORDS_FILE}" > "${JSON_FILE}"
  fi

  exec 3>&-
  tmpfile_cleanup "${JSON_RECORDS_FILE}"
fi

# End of run
