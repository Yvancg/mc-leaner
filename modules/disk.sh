#!/usr/bin/env bash
# shellcheck shell=bash

# mc-leaner: disk
# Purpose: Attribute top disk consumers across common locations (Application Support, caches, logs, containers, toolchains).
# Safety: Inspection-only. No deletes, no moves. --apply is ignored.
#
# Contract (disk.sh -> mc-leaner.sh)
#   - Exports:
#       - run_disk_module
#       - DISK_CHECKED_COUNT (int) : number of candidate items inspected (directories evaluated)
#       - DISK_FLAGGED_COUNT (int) : number of items >= DISK_THRESHOLD_MB (across all scanned candidates)
#       - DISK_TOTAL_MB      (int) : total MB across flagged items (sum of mb values)
#       - DISK_PRINTED_COUNT (int) : number of items emitted (<= DISK_TOP_N)
#       - DISK_DUR_S        (int) : best-effort wall clock duration in seconds for this module
#       - DISK_THRESHOLD_MB  (int) : threshold used for flagging (MB)
#       - DISK_TOP_N         (int) : maximum items emitted
#   - Entry point signature:
#       run_disk_module <mode> <apply> <backup_dir> <explain> [inventory_index_file]
#   - Inputs:
#       - inventory_index_file (optional): inventory index created by inventory.sh (used for owner attribution).
#   - Output (stdout):
#       - One line per emitted item:
#           DISK? <size>MB | owner: <owner> | conf: <low|medium|high> | category: <...> | path: <path>
#       - A final summary line:
#           Disk: inspected <checked> item(s); flagged=<flagged> total_mb=<total_mb> printed=<printed> (top_n=<top_n> threshold=<threshold>MB)
#   - Exit codes:
#       - 0 on success; non-zero only on unexpected runtime failure.
#
# Attribution confidence (conf)
#   - high:
#       - Matched against inventory index (apps/Homebrew), OR
#       - Recognized toolchain/dev roots (Homebrew, npm/pnpm/yarn, cargo, pip cache, gradle, m2, Xcode)
#   - medium:
#       - Bundle-id-like leaf under Containers / Group Containers / Preferences, OR
#       - Vendor folder inferred under Library/Application Support
#   - low:
#       - Heuristic name-only inference (e.g., leaf name under Caches/Logs), OR
#       - Unknown

 # NOTE: This module is inspection-only and uses best-effort probing.
# It enables pipefail but avoids `set -euo pipefail` to prevent aborting on expected permission/absence errors.
set -o pipefail

 # ----------------------------
# Logging Fallbacks
# ----------------------------

if ! command -v log_info >/dev/null 2>&1; then
  log_info() {
    # Purpose: Fallback logger when the module is executed standalone.
    printf '%s\n' "$*"
  }
fi

if ! command -v log_explain >/dev/null 2>&1; then
  log_explain() {
    # Purpose: Fallback explain logger when the module is executed standalone.
    printf '[EXPLAIN] %s\n' "$*"
  }
fi

 # ----------------------------
# Explain Helper
# ----------------------------

_disk_explain() {
  # Purpose: Emit explain lines only when explain=true.
  # Usage: _disk_explain "message"
  local msg="$1"
  if _disk_is_true "${DISK_EXPLAIN:-false}"; then
    log_explain "$msg"
  fi
}

 # ----------------------------
# Small Helpers
# ----------------------------

_disk_is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

_disk_du_kb() {
  # Purpose: Return integer KB for a path (permission errors suppressed).
  local p="$1"
  if [[ -z "$p" || ! -e "$p" ]]; then
    echo 0
    return 0
  fi
  local kb
  kb="$(LC_ALL=C du -sk "$p" 2>/dev/null | awk 'NR==1{print $1+0}')"
  if [[ -z "$kb" ]]; then
    echo 0
  else
    echo "$kb"
  fi
}

_disk_kb_to_mb_round() {
  # Purpose: Convert integer KB to integer MB (rounded).
  local kb="${1:-0}"
  awk -v kb="$kb" 'BEGIN{ if(kb<=0){print 0; exit} printf("%d", int((kb/1024)+0.5)) }'
}

_disk_normalize() {
  # Purpose: Normalize a token (lowercase, strip non-alphanumerics).
  echo "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'
}

 # ----------------------------
# Attribution Helpers
# ----------------------------

_disk_owner_from_inventory() {
  # Best-effort lookup against an inventory index file.
  # Heuristic: match normalized token anywhere on a line.
  # Output: prints owner string and returns 0 on success.
  local inventory_index_file="${1:-}"
  local token_raw="${2:-}"
  local token
  token="$(_disk_normalize "$token_raw")"

  if [[ -z "$inventory_index_file" || ! -f "$inventory_index_file" || -z "$token" ]]; then
    return 1
  fi

  local line
  line="$(LC_ALL=C grep -i -m 1 -E "(^|[^a-z0-9])${token}([^a-z0-9]|$)" "$inventory_index_file" 2>/dev/null || true)"
  [[ -z "$line" ]] && return 1

  # Prefer an "owner:" segment when present.
  local owner
  owner="$(echo "$line" | sed -nE 's/.*owner:[[:space:]]*([^|,]+).*/\1/p' | head -n 1 | sed -E 's/[[:space:]]+$//')"
  if [[ -n "$owner" ]]; then
    printf '%s' "$owner"
    return 0
  fi

  # Otherwise take first non-empty field split by tab or '|'.
  owner="$(echo "$line" | awk -F'[\t|]' '{for(i=1;i<=NF;i++){gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i); if($i!=""){print $i; exit}}}')"
  [[ -n "$owner" ]] || return 1
  printf '%s' "$owner"
}

_disk_infer_owner() {
  # Outputs: "<owner>|<confidence>"
  local p="$1"
  local inventory_index_file="${2:-}"

  local b
  b="$(basename "$p")"

  # 1) Inventory match (highest confidence)
  local inv_owner
  inv_owner="$(_disk_owner_from_inventory "$inventory_index_file" "$b" || true)"
  if [[ -n "$inv_owner" ]]; then
    printf '%s|%s' "$inv_owner" "high"
    return 0
  fi

  # 2) Bundle-id-ish leaf under common macOS containers/preferences.
  if [[ "$p" == *"/Library/Containers/"* || "$p" == *"/Library/Group Containers/"* || "$p" == *"/Library/Preferences/"* ]]; then
    local bid
    bid="$(echo "$b" | sed -nE 's/^([A-Za-z0-9_-]+\.)+[A-Za-z0-9_-]+$/&/p')"
    if [[ -n "$bid" ]]; then
      printf '%s|%s' "$bid" "medium"
      return 0
    fi
  fi

  # 3) Toolchains / dev clutter
  case "$p" in
    *"/opt/homebrew"*|*"/usr/local"*) printf '%s|%s' "Homebrew" "high"; return 0 ;;
    *"/.cargo"*|*"/Cargo"*) printf '%s|%s' "Rust (cargo)" "high"; return 0 ;;
    *"/.npm"*|*"/npm"*) printf '%s|%s' "Node (npm)" "high"; return 0 ;;
    *"/.pnpm"*|*"/pnpm"*) printf '%s|%s' "Node (pnpm)" "high"; return 0 ;;
    *"/.yarn"*|*"/yarn"*) printf '%s|%s' "Node (yarn)" "high"; return 0 ;;
    *"/.cache/pip"*|*"/pip"*) printf '%s|%s' "Python (pip)" "high"; return 0 ;;
    *"/.gradle"*) printf '%s|%s' "Gradle" "high"; return 0 ;;
    *"/.m2"*) printf '%s|%s' "Maven" "high"; return 0 ;;
    *"/Xcode"*|*"/DerivedData"*|*"/Archives"*) printf '%s|%s' "Xcode" "high"; return 0 ;;
  esac

  # 4) Vendor folder under Application Support
  if [[ "$p" == *"/Library/Application Support/"* ]]; then
    local vendor
    vendor="$(echo "$p" | sed -nE 's#^.*/Library/Application Support/([^/]+).*$#\1#p')"
    if [[ -n "$vendor" ]]; then
      printf '%s|%s' "$vendor" "medium"
      return 0
    fi
  fi

  # 5) Caches/Logs by leaf name
  if [[ "$p" == *"/Library/Caches/"* || "$p" == *"/Library/Logs/"* ]]; then
    local leaf
    leaf="$(basename "$p")"
    if [[ -n "$leaf" ]]; then
      printf '%s|%s' "$leaf" "low"
      return 0
    fi
  fi

  printf '%s|%s' "Unknown" "low"
}

_disk_category_for_path() {
  local p="$1"
  case "$p" in
    *"/Library/Application Support"*) echo "Application Support" ;;
    *"/Library/Caches"*) echo "Caches" ;;
    *"/Library/Logs"*) echo "Logs" ;;
    *"/opt/homebrew"*|*"/usr/local"*|*"/.cargo"*|*"/.npm"*|*"/.pnpm"*|*"/.yarn"*|*"/.gradle"*|*"/.m2"*|*"/Xcode"*|*"/DerivedData"*|*"/Archives"*) echo "Toolchains" ;;
    *) echo "Other" ;;
  esac
}

 # ----------------------------
# Output Helpers
# ----------------------------

_disk_emit_item() {
  # Format:
  # DISK? <size> | owner: <owner> | conf: <conf> | category: <cat> | path: <path>
  local mb="$1"
  local owner="$2"
  local conf="$3"
  local cat="$4"
  local p="$5"

  printf 'DISK? %sMB | owner: %s | conf: %s | category: %s | path: %s\n' "$mb" "$owner" "$conf" "$cat" "$p"
}

 # ----------------------------
# Collectors
# ----------------------------

_disk_collect_sizes() {
  # Writes: "mb<TAB>path" lines to the provided output file.
  local out_file="$1"
  local min_mb="$2"
  local home="${HOME:-}"

  local -a roots
  roots=(
    "$home/Library/Application Support"
    "$home/Library/Caches"
    "$home/Library/Logs"
    "/Library/Logs"
    "$home/Library/Containers"
    "$home/Library/Group Containers"
    "/opt/homebrew"
    "/usr/local"
    "$home/.cargo"
    "$home/.npm"
    "$home/.pnpm"
    "$home/.yarn"
    "$home/.gradle"
    "$home/.m2"
    "$home/Library/Developer/Xcode/DerivedData"
    "$home/Library/Developer/Xcode/Archives"
  )

  _disk_explain "Disk (explain): roots (existing only):"
  local r
  for r in "${roots[@]}"; do
    [[ -d "$r" ]] && _disk_explain "  - ${r}"
  done
  _disk_explain "Disk (explain): threshold=${min_mb}MB"

  local root
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue

    # For toolchain roots, include the root itself.
    case "$root" in
      "/opt/homebrew"|"/usr/local"|"$home/.cargo"|"$home/.npm"|"$home/.pnpm"|"$home/.yarn"|"$home/.gradle"|"$home/.m2"|"$home/Library/Developer/Xcode/DerivedData"|"$home/Library/Developer/Xcode/Archives")
        local root_kb root_mb
        root_kb="$(_disk_du_kb "$root")"
        root_mb="$(_disk_kb_to_mb_round "$root_kb")"
        printf '%s\t%s\n' "$root_mb" "$root" >>"$out_file"
        ;;
    esac

    # Direct child directories.
    local child
    while IFS= read -r child; do
      local kb mb
      kb="$(_disk_du_kb "$child")"
      mb="$(_disk_kb_to_mb_round "$kb")"
      printf '%s\t%s\n' "$mb" "$child" >>"$out_file"
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)
  done
}

 # ----------------------------
# Module Entry Point
# ----------------------------

run_disk_module() {
  # Contract:
  #   run_disk_module <mode> <apply> <backup_dir> <explain> [inventory_index_file]
  local mode="${1:-scan}"
  local apply="${2:-false}"
  local backup_dir="${3:-}"
  local explain="${4:-false}"
  local inventory_index_file="${5:-}"

  # Inputs
  log_info "Disk: mode=${mode} apply=${apply} backup_dir=${backup_dir} explain=${explain} inventory_index=${inventory_index_file:-<none>} (inspection-only; apply ignored)"

  # Reserved args for contract consistency (unused by this inspection-only module).
  : "${mode}" "${backup_dir}"

  # Timing (best-effort wall clock duration for this module).
  local _disk_t0="" _disk_t1=""
  _disk_t0="$(/bin/date +%s 2>/dev/null || echo '')"
  DISK_DUR_S=0


  # Explain flag is used throughout via DISK_EXPLAIN.
  DISK_EXPLAIN="${explain}"

  # Inspection-only: do nothing destructive in any mode.
  if _disk_is_true "${apply}"; then
    _disk_explain "Disk usage attribution is inspection-only; apply=true is ignored."
  fi

  local min_mb=200
  local top_n=20

  # Exported module settings for mc-leaner summary integration.
  DISK_THRESHOLD_MB="${min_mb}"
  DISK_TOP_N="${top_n}"

  local tmp
  tmp="$(mktemp -t mcleaner_disk.XXXXXX 2>/dev/null)" || {
    log_info "Disk: ERROR: failed to create temp file"
    return 1
  }

  # Ensure cleanup on all exits.
  trap 'rm -f "${tmp}" 2>/dev/null || true' RETURN

  _disk_collect_sizes "${tmp}" "${min_mb}"

  local checked=0
  local flagged=0
  local printed=0
  local total_mb=0

  # Collect identifiers for flagged disk items (paths).
  local -a _disk_flagged_ids=()

  # Sort by size (descending). Count all items >= threshold, but only emit top N.
  local mb p
  while IFS=$'\t' read -r mb p; do
    mb="${mb:-0}"
    [[ -n "${p}" ]] || continue

    checked=$((checked + 1))

    if (( mb < min_mb )); then
      _disk_explain "Disk: skip (below threshold ${min_mb}MB): ${mb}MB | ${p}"
      continue
    fi

    flagged=$((flagged + 1))
    total_mb=$((total_mb + mb))
    _disk_flagged_ids+=("${p}")

    if (( printed < top_n )); then
      local owner_conf owner conf cat
      owner_conf="$(_disk_infer_owner "${p}" "${inventory_index_file}")"
      owner="${owner_conf%|*}"
      conf="${owner_conf#*|}"
      cat="$(_disk_category_for_path "${p}")"

      _disk_emit_item "${mb}" "${owner}" "${conf}" "${cat}" "${p}"
      printed=$((printed + 1))
    fi
  done < <(LC_ALL=C sort -rn -k1,1 "${tmp}" 2>/dev/null)

  # Exported summary fields for mc-leaner.
  DISK_CHECKED_COUNT="${checked}"
  DISK_FLAGGED_COUNT="${flagged}"
  DISK_TOTAL_MB="${total_mb}"
  DISK_PRINTED_COUNT="${printed}"

  # Export flagged identifiers list for run summary consumption.
  DISK_FLAGGED_IDS_LIST="$(printf '%s\n' "${_disk_flagged_ids[@]}")"

  _disk_t1="$(/bin/date +%s 2>/dev/null || echo '')"
  if [[ -n "${_disk_t0}" && -n "${_disk_t1}" ]]; then
    DISK_DUR_S=$((_disk_t1 - _disk_t0))
  fi

  log_info "Disk: inspected ${checked} item(s); flagged=${flagged} total_mb=${total_mb} printed=${printed} (top_n=${top_n} threshold=${min_mb}MB)"
}