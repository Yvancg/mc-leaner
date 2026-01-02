#!/bin/bash
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
  # Scan configuration
  # ----------------------------
  local min_mb=200  # TODO: make configurable via CLI when the interface stabilizes

  log "Caches: scanning user-level cache locations (min ${min_mb}MB)..."

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

  _guess_owner_app() {
    # Purpose: best-effort mapping from cache folder naming to an owning app identifier
    local p="$1"
    local base
    base="$(basename "$p")"

    # Common pattern: bundle identifier (com.vendor.app)
    if [[ "$base" == *.*.* ]]; then
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

    # Container path pattern: ~/Library/Containers/<bundle-id>/...
    if [[ "$p" == *"/Library/Containers/"*"/Data/Library/Caches"* ]]; then
      local cid
      cid="$(echo "$p" | awk -F'/Library/Containers/' '{print $2}' | awk -F'/' '{print $1}')"
      [[ -n "$cid" ]] && echo "$cid" && return 0
    fi

    echo "$base"
  }

  # ----------------------------
  # Scan targets (user-level only)
  # ----------------------------
  local home="$HOME"
  local candidates=()

  local scanned_dirs=0
  local over_threshold=0
  local below_report_file
  below_report_file="$(tmpfile)"

  # ----------------------------
  # Batch size scan (much faster than per-dir du)
  # ----------------------------

  # Target 1: ~/Library/Caches/* (one level)
  if [[ -d "$home/Library/Caches" ]]; then
    explain_log "Caches (explain): sizing ~/Library/Caches/*"

    # du output: <kb>\t<path>
    while IFS=$'\t' read -r kb d; do
      [[ -n "$kb" && -n "$d" ]] || continue
      [[ -d "$d" ]] || continue

      scanned_dirs=$((scanned_dirs + 1))
      local mb=$((kb / 1024))

      if (( mb >= min_mb )); then
        candidates+=("$d")
        over_threshold=$((over_threshold + 1))
      else
        # Track below-threshold items for --explain diagnostics (size|path)
        printf "%s|%s\n" "$mb" "$d" >>"$below_report_file"
      fi
    done < <(du -sk "$home/Library/Caches"/* 2>/dev/null || true)
  fi

  # Target 2: ~/Library/Containers/*/Data/Library/Caches (batched)
  if [[ -d "$home/Library/Containers" ]]; then
    explain_log "Caches (explain): finding container cache dirs"

    while IFS=$'\t' read -r kb d; do
      [[ -n "$kb" && -n "$d" ]] || continue
      [[ -d "$d" ]] || continue

      scanned_dirs=$((scanned_dirs + 1))
      local mb=$((kb / 1024))

      if (( mb >= min_mb )); then
        candidates+=("$d")
        over_threshold=$((over_threshold + 1))
      else
        # Track below-threshold items for --explain diagnostics (size|path)
        printf "%s|%s\n" "$mb" "$d" >>"$below_report_file"
      fi
    done < <(
      find "$home/Library/Containers" -maxdepth 3 -type d -path "*/Data/Library/Caches" -print0 2>/dev/null \
        | xargs -0 du -sk 2>/dev/null || true
    )
  fi

  explain_log "Caches (explain): sizing complete"

  log "Caches: scanned ${scanned_dirs} directories; found ${over_threshold} >= ${min_mb}MB."

  if [[ "${#candidates[@]}" -eq 0 ]]; then
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
  report_file="$(tmpfile)"

  for d in "${candidates[@]}"; do
    local kb mb mod owner
    kb="$(_du_kb "$d")"
    mb=$((kb / 1024))
    mod="$(_mtime "$d")"
    owner="$(_guess_owner_app "$d")"

    # Format: owner|mb|mtime|path
    printf "%s|%s|%s|%s\n" "$owner" "$mb" "$mod" "$d" >>"$report_file"
  done

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

    # Explain-only: show top subfolders by size (up to 3)
    if [[ "${EXPLAIN:-false}" == "true" ]]; then
      explain_log "  Subfolders (top 3 by size):"
      du -sk "${path}"/* 2>/dev/null \
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
        safe_move_path "$path" "$backup_dir"
        log "Moved: $path"
      fi
    fi
  done <"${report_file}.sorted"

  # Flush last owner total
  if [[ -n "$current_owner" ]]; then
    log "CACHE: ${current_owner} | total: ${owner_total_mb}MB"
  fi

  log "Caches: total large caches (by heuristics): ${overall_total_mb}MB"
  log "Caches: scanned ${scanned_dirs} directories; listed ${over_threshold} >= ${min_mb}MB."
  explain_log "Caches: run with --apply to relocate selected caches (user-confirmed, reversible)"
}

# End of module
