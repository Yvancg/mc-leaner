#!/bin/bash
# shellcheck shell=bash
# mc-leaner: caches inspection module
# Purpose: Inspect user-level cache locations and surface large cache directories for review
# Safety: User-level only; defaults to dry-run; never deletes; cleanup relocates caches to backups with confirmation

# NOTE: Modules run with strict mode for deterministic failures and auditability.

set -euo pipefail

# Suppress SIGPIPE noise when output is piped to a consumer that exits early (e.g., `head -n`).
# Safety: logging/output ergonomics only; does not affect inspection results.
trap '' PIPE

# ----------------------------
# Defensive Checks
# ----------------------------
# Purpose: Provide safe fallbacks when shared helpers are not loaded.
# Safety: Logging only; must not change inspection or cleanup behavior.
if ! type explain_log >/dev/null 2>&1; then
  explain_log() {
    # Purpose: Best-effort verbose logging when --explain is enabled.
    # Safety: Logging only.
    if [[ "${EXPLAIN:-false}" == "true" ]]; then
      log "$@"
    fi
  }
fi

# ----------------------------
# Module Entry Point
# ----------------------------
run_caches_module() {
  # Contract:
  #   run_caches_module <mode> <apply> <backup_dir> <explain> [inventory_index_file]
  local mode="${1:-scan}"        # scan|clean
  local apply="${2:-false}"      # true|false
  local backup_dir="${3:-}"
  local explain="${4:-false}"
  local inventory_index_file="${5:-}"

  # Inputs
  # Sanitize inventory_index_file before logging to avoid multi-line noise.
  if [[ -n "${inventory_index_file:-}" ]]; then
    local _inv_sane=""
    _inv_sane="$(
      { printf '%s\n' "${inventory_index_file}"; } 2>/dev/null \
        | grep -Eo '(/(var/folders|tmp)/[^[:space:]]*mc-leaner_inventory\.[^[:space:]]+)' \
        | tail -n 1
    )" || true
    if [[ -n "${_inv_sane:-}" ]]; then
      inventory_index_file="${_inv_sane}"
    fi
  fi

  log "Caches: mode=${mode} apply=${apply} backup_dir=${backup_dir} explain=${explain} inventory_index=${inventory_index_file:-<none>}"

  # Reserved args for contract consistency (modules share a stable CLI signature).
  : "${mode}" "${backup_dir}" "${inventory_index_file}"

  # Explain flag used throughout via EXPLAIN.
  local _caches_prev_explain="${EXPLAIN:-false}"
  EXPLAIN="${explain}"

  # Timing (best-effort wall clock duration for this module).
  local _caches_t0="" _caches_t1=""
  _caches_t0="$(/bin/date +%s 2>/dev/null || echo '')"
  CACHES_DUR_S=0

  _caches_finish_timing() {
    # SAFETY: must be safe under `set -u` and when invoked on early returns.
    _caches_t1="$(/bin/date +%s 2>/dev/null || echo '')"

    if [[ -n "${_caches_t0:-}" && -n "${_caches_t1:-}" ]] \
      && [[ "${_caches_t0}" =~ ^[0-9]+$ ]] \
      && [[ "${_caches_t1}" =~ ^[0-9]+$ ]]; then
      CACHES_DUR_S=$((_caches_t1 - _caches_t0))
    else
      CACHES_DUR_S=0
    fi
  }

  _caches_on_return() {
    EXPLAIN="${_caches_prev_explain:-false}"
    _caches_finish_timing
  }
  trap _caches_on_return RETURN

  # ----------------------------
  # Helper: inventory path sanitizer
  # ----------------------------
  _caches_extract_inventory_path() {
    # Usage: _caches_extract_inventory_path "<maybe polluted string>"
    # Returns: best-effort single path to an existing inventory index file, else empty.
    local s="${1:-}"
    local cand=""

    [[ -n "${s}" ]] || return 1

    # 1) Exact path works
    if [[ -f "${s}" ]]; then
      printf '%s\n' "${s}"
      return 0
    fi

    # 2) Extract the last plausible inventory file path from a polluted multi-line string.
    # Matches /var/folders/.../T/mc-leaner_inventory.* or /tmp/.../mc-leaner_inventory.*
    cand="$(
      { printf '%s\n' "${s}"; } 2>/dev/null \
        | grep -Eo '(/(var/folders|tmp)/[^[:space:]]*mc-leaner_inventory\.[^[:space:]]+)' \
        | tail -n 1
    )" || true

    if [[ -n "${cand}" && -f "${cand}" ]]; then
      printf '%s\n' "${cand}"
      return 0
    fi

    return 1
  }

  # ----------------------------
  # Helper: _inventory_ready
  # ----------------------------
  _inventory_ready() {
    # Purpose: determine whether an inventory index file is available and usable.
    # Safety: read-only; sanitizes polluted values (e.g., when caller captured logs into the arg).

    local p=""

    # Prefer the explicit arg, but sanitize it.
    if p="$(_caches_extract_inventory_path "${inventory_index_file:-}" 2>/dev/null)"; then
      inventory_index_file="${p}"
      return 0
    fi

    # Fallback to runner-exported env vars.
    if [[ "${INVENTORY_READY:-false}" == "true" ]]; then
      if p="$(_caches_extract_inventory_path "${INVENTORY_INDEX_FILE:-}" 2>/dev/null)"; then
        export INVENTORY_INDEX_FILE="${p}"
        return 0
      fi
    fi

    return 1
  }

  # ----------------------------
  # Scan Configuration
  # ----------------------------
  local min_mb=200  # TODO: make configurable via CLI when the interface stabilizes

  log "Caches: scanning user-level cache locations (min ${min_mb}MB)..."

  if [[ "${EXPLAIN:-false}" == "true" ]]; then
    if _inventory_ready; then
      explain_log "Caches (explain): inventory index available; owner labels will prefer inventory lookups"
    else
      explain_log "Caches (explain): inventory index not available; owner labels will use folder naming/Spotlight heuristics"
    fi
  fi

  # ----------------------------
  # Helper: Size and Timestamps
  # ----------------------------
  _mtime() {
    # Purpose: Return last modified time as a readable string (macOS stat).
    local epoch
    epoch="$(stat -f "%m" "$1" 2>/dev/null || echo "")"
    [[ -n "$epoch" ]] && date -r "$epoch" +"%Y-%m-%d %H:%M:%S" || echo "unknown"
  }

  _norm_key() {
    # Purpose: Normalize a name into an inventory-style key.
    # Example: "Google Drive" -> "googledrive"; "group.is.workflow.shortcuts" -> "groupisworkflowshortcuts".
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
  }

  _inventory_lookup() {
    # Usage: _inventory_lookup <key>
    # Index format (expected): key<TAB>name<TAB>source<TAB>path
    # Defensive: tolerate variable field counts.
    local key="$1"
    local idx_file="${inventory_index_file:-${INVENTORY_INDEX_FILE:-}}"
    local out

    _inventory_ready || return 1

    # Safe exact-key match (case-insensitive) without regex pitfalls.
    # Prints: "Name (src)|path" when available, else best-effort.
    out="$(
      awk -F'\t' -v k="$key" '
        function lc(s){ return tolower(s) }
        lc($1)==lc(k) {
          name=($2!=""?$2:"");
          src=($3!=""?$3:"");
          path=($4!=""?$4:"");
          if (name!="" && path!="") { print name " (" src ")|" path; exit }
          if (name!="") { print name; exit }
          print $0; exit
        }
      ' "${idx_file}" 2>/dev/null
    )"

    [[ -n "$out" ]] || return 1
    echo "$out"
  }

  _inventory_label_from_bundle_id() {
    # Try bundle id as-is and also common transforms for Group Containers/team-id prefixes
    local bid="$1"
    local key out

    [[ -n "$bid" ]] || return 1

    # 1) direct bundle id key
    key="$bid"
    if out="$(_inventory_lookup "$key" 2>/dev/null)" && [[ -n "$out" ]]; then
      echo "$out"
      return 0
    fi

    # 2) strip leading TEAMID. (e.g., EQHXZ8M8AV.group.com.google.drivefs -> group.com.google.drivefs)
    if [[ "$bid" =~ ^[A-Z0-9]{10}\.(.+)$ ]]; then
      key="${BASH_REMATCH[1]}"
      if out="$(_inventory_lookup "$key" 2>/dev/null)" && [[ -n "$out" ]]; then
        echo "$out"
        return 0
      fi
    fi

    # 3) strip group. prefix (common for group containers)
    if [[ "$bid" =~ ^group\.(.+)$ ]]; then
      key="${BASH_REMATCH[1]}"
      if out="$(_inventory_lookup "$key" 2>/dev/null)" && [[ -n "$out" ]]; then
        echo "$out"
        return 0
      fi
    fi

    return 1
  }

  _inventory_label_from_name() {
    # Try normalized name key (e.g., "Google" -> "google")
    local name="$1"
    local key out
    [[ -n "$name" ]] || return 1

    key="$(_norm_key "$name")"
    [[ -n "$key" ]] || return 1

    if out="$(_inventory_lookup "$key" 2>/dev/null)" && [[ -n "$out" ]]; then
      echo "$out"
      return 0
    fi

    return 1
  }

  _guess_owner_app() {
    # Purpose: Map a cache directory to an owning app label using Inventory when possible.
    # Returns a human label suitable for logs. Does not perform any writes.
    local p="$1"
    local base out
    base="$(basename "$p")"

    # 0) Treat Apple container caches as protected system-owned.
    # Avoid surfacing them as user cleanup candidates.
    if [[ "$p" == "$HOME/Library/Containers/com.apple."*"/Data/Library/Caches"* ]] || \
       [[ "$p" == "$HOME/Library/Group Containers/group.com.apple."* ]]; then
      echo "Apple (system)"
      return 0
    fi

    # 0b) Improve labeling for shared Google cache root.
    # On your system this is dominated by Chrome profiles.
    if [[ "$p" == "$HOME/Library/Caches/Google" ]]; then
      if [[ -d "$p/Chrome" ]]; then
        echo "Google Chrome"
      else
        echo "Google (shared)"
      fi
      return 0
    fi

    # 1) Container cache pattern: ~/Library/Containers/<bundle-id>/Data/Library/Caches
    if [[ "$p" == *"/Library/Containers/"*"/Data/Library/Caches"* ]]; then
      local cid
      cid="$(echo "$p" | awk -F'/Library/Containers/' '{print $2}' | awk -F'/' '{print $1}')"
      if [[ -n "$cid" ]]; then
        if out="$(_inventory_label_from_bundle_id "$cid" 2>/dev/null)"; then
          # If inventory returns "Name (src)|path", keep only the name portion for compact logs
          echo "$out" | awk -F'\|' '{print $1}'
          return 0
        fi
        echo "$cid"
        return 0
      fi
    fi

    # 2) Bundle-id looking folder name under ~/Library/Caches (com.vendor.app)
    if [[ "$base" == *.*.* ]]; then
      if out="$(_inventory_label_from_bundle_id "$base" 2>/dev/null)"; then
        echo "$out" | awk -F'\|' '{print $1}'
        return 0
      fi

      # Fallback: Spotlight lookup (slower; avoid unless necessary)
      local hit=""
      if is_cmd mdfind; then
        hit="$(mdfind "kMDItemCFBundleIdentifier == '$base'" 2>/dev/null | head -n 1 || true)"
      fi
      if [[ -n "$hit" ]]; then
        echo "$(basename "$hit" .app) ($base)"
        return 0
      fi

      echo "$base"
      return 0
    fi

    # 3) Non bundle-id folder name (e.g. Google, Chrome, Microsoft). Try inventory normalized name.
    if out="$(_inventory_label_from_name "$base" 2>/dev/null)" && [[ -n "$out" ]]; then
      echo "$out" | awk -F'\|' '{print $1}'
      return 0
    fi

    # 4) Default: folder basename
    echo "$base"
  }

  # ----------------------------
  # Tempfile helper
  # ----------------------------
  _caches_tmpfile() {
    # Purpose: create a temp file path (stdout only) without relying on shared tmpfile helper.
    # Safety: creates an empty temp file and returns its path.
    local t=""

    t="$(/usr/bin/mktemp -t mc-leaner.XXXXXX 2>/dev/null || true)"
    if [[ -z "${t}" ]]; then
      t="/tmp/mc-leaner.${RANDOM}.${RANDOM}"
      : >"${t}" 2>/dev/null || true
    fi

    printf '%s\n' "${t}"
  }

  # ----------------------------
  # Scan Targets (User-Level Only)
  # ----------------------------
  local home="$HOME"

  local scanned_dirs=0
  local over_threshold=0
  local below_report_file
  below_report_file="$(_caches_tmpfile 2>/dev/null | tail -n 1)"

  # Collect candidates as "kb<TAB>path" so we can de-dup safely later.
  local candidate_list_file
  candidate_list_file="$(_caches_tmpfile 2>/dev/null | tail -n 1)"

  # Best-effort cleanup of temp files created by this module.
  _caches_cleanup_tmp() {
    # SAFETY: this EXIT trap can run after `run_caches_module` returns.
    # Use locals so we do not re-expand variables multiple times under `set -u`.
    local _bf="${below_report_file:-}"
    local _cf="${candidate_list_file:-}"
    local _ckp="${candidates_kb_path:-}"
    local _rf="${report_file:-}"

    rm -f \
      "${_bf}" \
      "${_cf}" \
      "${_ckp}" \
      "${_rf}" \
      "${_rf}.sorted" \
      2>/dev/null || true
  }
  trap _caches_cleanup_tmp EXIT

  # ----------------------------
  # Batch Size Scan
  # ----------------------------

  # Target 1: ~/Library/Caches (one level children)
  if [[ -d "$home/Library/Caches" ]]; then
    explain_log "Caches (explain): sizing ~/Library/Caches (one level)"

    # Avoid glob expansion (can hit arg limits on large systems).
    # du output: <kb>\t<path>
    while IFS=$'\t' read -r kb d; do
      [[ -n "${kb:-}" && -n "${d:-}" ]] || continue
      [[ "${kb}" =~ ^[0-9]+$ ]] || continue
      [[ -d "${d}" ]] || continue

      # Skip Apple/system container caches (noise, not user cleanup material)
      if [[ "$d" == "$home/Library/Containers/com.apple."*"/Data/Library/Caches"* ]]; then
        continue
      fi

      scanned_dirs=$((scanned_dirs + 1))
      local mb=$((kb / 1024))

      if (( mb >= min_mb )); then
        printf "%s\t%s\n" "$kb" "$d" >>"$candidate_list_file"
      else
        # Track below-threshold items for --explain diagnostics (size|path)
        printf "%s|%s\n" "$mb" "$d" >>"$below_report_file"
      fi
    done < <(
      find "$home/Library/Caches" -mindepth 1 -maxdepth 1 -type d -exec du -sk {} + 2>/dev/null || true
    )
  fi

  # Target 2: ~/Library/Containers/*/Data/Library/Caches (batched)
  if [[ -d "$home/Library/Containers" ]]; then
    explain_log "Caches (explain): finding container cache dirs"

    while IFS=$'\t' read -r kb d; do
      [[ -n "${kb:-}" && -n "${d:-}" ]] || continue
      [[ "${kb}" =~ ^[0-9]+$ ]] || continue
      [[ -d "${d}" ]] || continue

      # Skip Apple/system container caches (noise, not user cleanup material)
      if [[ "$d" == "$home/Library/Containers/com.apple."*"/Data/Library/Caches" ]]; then
        continue
      fi

      scanned_dirs=$((scanned_dirs + 1))
      local mb=$((kb / 1024))

      if (( mb >= min_mb )); then
        printf "%s\t%s\n" "$kb" "$d" >>"$candidate_list_file"
      else
        # Track below-threshold items for --explain diagnostics (size|path)
        printf "%s|%s\n" "$mb" "$d" >>"$below_report_file"
      fi
    done < <(
      find "$home/Library/Containers" -mindepth 4 -maxdepth 4 -type d -path "*/Data/Library/Caches" -exec du -sk {} + 2>/dev/null || true
    )
  fi

  explain_log "Caches (explain): sizing complete"

  # De-dup candidate paths (same cache dir may be discovered via multiple roots).
  local candidates_kb_path
  candidates_kb_path="$(_caches_tmpfile 2>/dev/null | tail -n 1)"

  if [[ -s "$candidate_list_file" ]]; then
    # Sort by path (2nd field) then keep first occurrence per path.
    sort -t$'\t' -k2,2 "$candidate_list_file" 2>/dev/null \
      | awk -F'\t' '!seen[$2]++ {print $0}' >"$candidates_kb_path" || true
  fi

  # Recompute over_threshold based on unique candidates.
  over_threshold=0
  if [[ -s "$candidates_kb_path" ]]; then
    over_threshold="$(wc -l <"$candidates_kb_path" | tr -d ' ')"
  fi

  # Update the log line to reflect unique candidates.
  log "Caches: scanned ${scanned_dirs} directories; found ${over_threshold} >= ${min_mb}MB."

  if [[ ! -s "${candidates_kb_path:-}" ]]; then
    log "Caches: no directories >= ${min_mb}MB found (by heuristics)."

    if [[ "${EXPLAIN:-false}" == "true" ]]; then
      log "Caches (explain): top 10 below threshold:"
      sort -t'|' -k1,1nr "$below_report_file" 2>/dev/null | head -n 10 | while IFS='|' read -r mb path; do
        log "  - ${mb}MB | ${path}"
      done
    fi

    return 0
  fi

  # ----------------------------
  # Report and Optional Relocation
  # ----------------------------
  local report_file
  local flagged_count=0
  local flagged_items=()
  local flagged_ids=()
  local move_failures=()
  report_file="$(_caches_tmpfile 2>/dev/null | tail -n 1)"
  local moved_count=0

  while IFS=$'\t' read -r kb d; do
    [[ -n "${kb:-}" && -n "${d:-}" ]] || continue
    [[ "${kb}" =~ ^[0-9]+$ ]] || continue
    [[ -d "${d}" ]] || continue

    local mb mod owner
    mb=$((kb / 1024))
    mod="$(_mtime "$d")"
    owner="$(_guess_owner_app "$d")"

    # Skip protected Apple/system cache locations from reporting/relocation
    if [[ "$owner" == "Apple (system)" ]]; then
      continue
    fi

    # Format: owner|mb|mtime|path
    printf "%s|%s|%s|%s\n" "$owner" "$mb" "$mod" "$d" >>"$report_file"
  done <"$candidates_kb_path"

  # Sort by owner, then by size desc
  sort -t'|' -k1,1 -k2,2nr "$report_file" >"${report_file}.sorted"

  local current_owner=""
  local owner_total_mb=0
  local overall_total_mb=0

  while IFS='|' read -r owner mb mod path; do
    if [[ "$owner" != "$current_owner" ]]; then
      # Flush previous owner total
      if [[ -n "$current_owner" ]]; then
        log "CACHE: ${current_owner} | total: ${owner_total_mb}MB"
        owner_total_mb=0
      fi
      current_owner="$owner"
      explain_log "CACHE GROUP: $current_owner"
    fi

    owner_total_mb=$((owner_total_mb + mb))
    overall_total_mb=$((overall_total_mb + mb))

    log "CACHE? ${mb}MB | modified: ${mod} | owner: ${owner} | path: ${path}"
    flagged_count=$((flagged_count + 1))
    flagged_items+=("${mb}MB | modified: ${mod} | owner: ${owner} | path: ${path}")
    flagged_ids+=("${path}")

    # Explain-only: show top subfolders by size (up to 3)
    if [[ "${EXPLAIN:-false}" == "true" ]]; then
      explain_log "  Subfolders (top 3 by size):"
      find "${path}" -mindepth 1 -maxdepth 1 -exec du -sk {} + 2>/dev/null \
        | sort -nr \
        | head -n 3 \
        | while read -r skb sub; do
            [[ "${skb:-}" =~ ^[0-9]+$ ]] || continue
            local smb=$((skb / 1024))
            explain_log "    - ${smb}MB | ${sub}"
          done
    fi

    # SAFETY: user-level cleanup only, explicit clean mode + --apply + confirmation
    if [[ "$mode" == "clean" && "$apply" == "true" ]]; then
      if [[ "$path" != "$HOME/"* ]]; then
        explain_log "SKIP (safety): refuses to move non-user path: $path"
        continue
      fi

      if ask_yes_no "Large cache detected:\n${path}\n\nMove to backup (reversible)?"; then
        local move_out
        if move_out="$(safe_move "$path" "$backup_dir" 2>&1)"; then
          # Contract: log both source and resolved destination for legibility.
          log "Moved: $path -> $move_out"
          moved_count=$((moved_count + 1))
        else
          # Contract: keep the item flagged, but surface a clear move failure summary at end-of-run.
          move_failures+=("$path | failed: $move_out")
          log "Caches: move failed: $path"
        fi
      fi
    fi
  done <"${report_file}.sorted"

  # Flush last owner total
  if [[ -n "$current_owner" ]]; then
    log "CACHE: ${current_owner} | total: ${owner_total_mb}MB"
  fi

  log "Caches: total large caches (by heuristics): ${overall_total_mb}MB"
  log "Caches: scanned ${scanned_dirs} directories; listed ${over_threshold} >= ${min_mb}MB."
  log "Caches: flagged ${flagged_count} item(s) >= ${min_mb}MB."
  log "Caches: flagged items:"
  for item in "${flagged_items[@]}"; do
    log "  - ${item}"
  done

  if [[ "${#move_failures[@]}" -gt 0 ]]; then
    log "Caches: move failures:"
    for f in "${move_failures[@]}"; do
      log "  - ${f}"
    done
  fi

  log "Caches: run with --apply to relocate selected caches (user-confirmed, reversible)"

  if [[ "${EXPLAIN:-false}" == "true" ]]; then
    explain_log "Caches (explain): flagged items are listed above for review."
  fi

  # ----------------------------
  # Module Summary
  # ----------------------------

  # Exported summary fields for mc-leaner.
  CACHES_FLAGGED_COUNT="${flagged_count}"
  CACHES_TOTAL_MB="${overall_total_mb}"
  CACHES_MOVED_COUNT="${moved_count}"
  CACHES_FAILURES_COUNT="${#move_failures[@]}"
  CACHES_SCANNED_DIRS="${scanned_dirs}"
  CACHES_THRESHOLD_MB="${min_mb}"

  # Export flagged identifiers list (paths) for run summary consumption.
  CACHES_FLAGGED_IDS_LIST="$({ printf '%s\n' "${flagged_ids[@]}"; } 2>/dev/null || true)"

  # Ensure timing is computed before returning from the module.
  _caches_on_return

  summary_add "Caches flagged=${flagged_count} total_mb=${overall_total_mb} moved=${moved_count} failures=${#move_failures[@]} scanned=${scanned_dirs} (threshold=${min_mb}MB)"
}

# End of module
