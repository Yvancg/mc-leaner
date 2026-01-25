#!/bin/bash
# shellcheck shell=bash
# mc-leaner: caches inspection module
# Purpose: Inspect user-level cache locations and surface large cache directories for review
# Safety: User-level only; defaults to dry-run; never deletes; cleanup relocates caches to backups with confirmation

set -euo pipefail

# ----------------------------
# Defensive: ensure explain_log exists (modules should not assume it)
# ----------------------------
if ! type explain_log >/dev/null 2>&1; then
  explain_log() {
    # Purpose: best-effort verbose logging when --explain is enabled
    # Safety: Logging only; does not change behavior
    if [[ "${EXPLAIN:-false}" == "true" ]]; then
      log "$@"
    fi
  }
fi

# ----------------------------
# Module entry point
# ----------------------------
run_caches_module() {
  local mode="$1"        # scan|clean
  local apply="$2"       # true|false
  local backup_dir="$3"

  # ----------------------------
  # Helper: _inventory_ready (moved before first use)
  # ----------------------------
  _inventory_ready() {
    [[ "${INVENTORY_READY:-false}" == "true" ]] && [[ -n "${INVENTORY_INDEX_FILE:-}" ]] && [[ -f "${INVENTORY_INDEX_FILE:-}" ]]
  }

  # ----------------------------
  # Scan configuration
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
  # Helper: size and timestamps (macOS compatible)
  # ----------------------------
  _du_kb() {
    # Purpose: return size in KB for a path (macOS-compatible du invocation)
    du -sk "$1" 2>/dev/null | awk '{print $1}'
  }

  _mtime() {
    # Purpose: return last modified time as a readable string (macOS stat)
    local epoch
    epoch="$(stat -f "%m" "$1" 2>/dev/null || echo "")"
    [[ -n "$epoch" ]] && date -r "$epoch" +"%Y-%m-%d %H:%M:%S" || echo "unknown"
  }

  _norm_key() {
    # Lowercase and remove non-alphanumerics for loose matching (matches inventory normalized keys)
    # Example: "Google Drive" -> "googledrive"; "group.is.workflow.shortcuts" -> "groupisworkflowshortcuts"
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
  }

  _inventory_lookup() {
    # Usage: _inventory_lookup <key>
    # Index format (expected): key<TAB>name<TAB>source<TAB>path
    # Defensive: tolerate variable field counts.
    local key="$1"
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
      ' "${INVENTORY_INDEX_FILE}" 2>/dev/null
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
    # Purpose: map a cache directory to an owning app label using Inventory when possible
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
  # Scan targets (user-level only)
  # ----------------------------
  local home="$HOME"

  local scanned_dirs=0
  local over_threshold=0
  local below_report_file
  below_report_file="$(tmpfile)"

  # Collect candidates as "kb<TAB>path" so we can de-dup safely later.
  local candidate_list_file
  candidate_list_file="$(tmpfile)"

  # Best-effort cleanup of temp files created by this module.
  _caches_cleanup_tmp() {
    # NOTE: This trap can run after `run_caches_module` returns, when locals may be unset.
    # Use `:-` defaults everywhere to avoid `set -u` unbound-variable failures.
    rm -f \
      "${below_report_file:-}" \
      "${candidate_list_file:-}" \
      "${candidates_kb_path:-}" \
      "${report_file:-}" \
      "${report_file:-}.sorted" \
      2>/dev/null || true
  }
  trap _caches_cleanup_tmp EXIT

  # ----------------------------
  # Batch size scan (much faster than per-dir du)
  # ----------------------------

  # Target 1: ~/Library/Caches (one level children)
  if [[ -d "$home/Library/Caches" ]]; then
    explain_log "Caches (explain): sizing ~/Library/Caches (one level)"

    # Avoid glob expansion (can hit arg limits on large systems).
    # du output: <kb>\t<path>
    while IFS=$'\t' read -r kb d; do
      [[ -n "$kb" && -n "$d" ]] || continue
      [[ -d "$d" ]] || continue

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
      [[ -n "$kb" && -n "$d" ]] || continue
      [[ -d "$d" ]] || continue

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
  candidates_kb_path="$(tmpfile)"

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
  # Report / optional relocation (grouped)
  # ----------------------------
  local report_file
  local flagged_count=0
  local flagged_items=()
  local move_failures=()
  report_file="$(tmpfile)"
  local moved_count=0

  while IFS=$'\t' read -r kb d; do
    [[ -n "$kb" && -n "$d" ]] || continue
    [[ -d "$d" ]] || continue

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

    # Explain-only: show top subfolders by size (up to 3)
    if [[ "${EXPLAIN:-false}" == "true" ]]; then
      explain_log "  Subfolders (top 3 by size):"
      find "${path}" -mindepth 1 -maxdepth 1 -exec du -sk {} + 2>/dev/null \
        | sort -nr \
        | head -n 3 \
        | while read -r skb sub; do
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
  # Module summary (global footer aggregation)
  # ----------------------------
  summary_add "Caches flagged=${flagged_count} total_mb=${overall_total_mb} moved=${moved_count} failures=${#move_failures[@]} scanned=${scanned_dirs} (threshold=${min_mb}MB)"
}

# End of module
