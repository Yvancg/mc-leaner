#!/bin/bash
# mc-leaner: intel module
# Purpose: Report Intel-only (x86_64) Mach-O executables for visibility on Apple Silicon systems
# Safety: Reporting-only. Never modifies, moves, or deletes files.

set -euo pipefail

# ----------------------------
# Entry point
# ----------------------------

run_intel_report() {
  # Allow either global EXPLAIN=true or an explicit arg ("true"/"false")
  local explain="${1:-${EXPLAIN:-false}}"
  : "${EXPLAIN:=false}"

  # ----------------------------
  # Report destination
  # ----------------------------
  local out="$HOME/Desktop/intel_binaries.txt"

  # ----------------------------
  # Scan roots
  # ----------------------------
  # Default roots (safe, broad).
  # If inventory is available, prefer scanning the concrete app bundle paths instead of whole directories.
  local roots=()

  if [[ "${INVENTORY_READY:-false}" == "true" && -n "${INVENTORY_FILE:-}" && -r "${INVENTORY_FILE:-}" ]]; then
    # Inventory rows are tab-separated:
    # app <source> <name> <bundle_id> <path>
    # We scan app bundle paths directly for speed and accuracy.
    while IFS=$'\t' read -r kind src name bid app_path; do
      [[ "$kind" == "app" ]] || continue
      [[ -n "$app_path" && "$app_path" == /* && -d "$app_path" ]] || continue
      roots+=("$app_path")
    done < "${INVENTORY_FILE}"

    # Keep /opt for vendor tools and package installs.
    roots+=("/opt")

    # Keep user Library for plugins/executables that are not inside app bundles.
    roots+=("$HOME/Library")
  else
    roots+=(
      "/Applications"
      "$HOME/Applications"
      "$HOME/Library"
      "/opt"
    )
  fi

  # De-duplicate roots (Bash 3.2 compatible, preserves order)
  # NOTE: with `set -u`, expanding an *unset* array triggers an error.
  # Always initialize the arrays we expand.
  local uniq_roots=()
  if [[ "${#roots[@]}" -gt 1 ]]; then
    local rr
    local seen
    local ur
    for rr in "${roots[@]}"; do
      [[ -n "$rr" ]] || continue
      seen="no"
      for ur in "${uniq_roots[@]}"; do
        if [[ "$ur" == "$rr" ]]; then
          seen="yes"
          break
        fi
      done
      [[ "$seen" == "yes" ]] || uniq_roots+=("$rr")
    done
    roots=("${uniq_roots[@]}")
  fi

  log "Scanning for Intel-only executables (informational)..."

  if [[ "$explain" == "true" ]]; then
    log "Intel: this scan may take several minutes on large systems"
  fi

  if [[ "$explain" == "true" ]]; then
    log "Intel (explain): scan roots:"
    local r
    for r in "${roots[@]}"; do
      log "  - ${r}"
    done
    log "Intel (explain): only files with executable bit set are scanned"
    log "Intel (explain): permission errors are suppressed to reduce noise"
  fi

  # NOTE:
  # - Uses `-perm +111` for macOS compatibility (deprecated elsewhere but reliable here)
  # - Errors are suppressed intentionally to avoid noise from protected paths
  # - This scan is informational only and has no side effects

  # ----------------------------
  # Intel-only executable scan
  # ----------------------------
  # We want Intel-only executables: x86_64 slice present AND no arm64/arm64e slice.
  # `file` output can be multi-line; we avoid that entirely by testing paths directly.
  # We prefer `lipo -archs` when available for accurate slice detection.

  # Build into a temp file first, then write a deterministic, sorted report.
  local tmp_out
  tmp_out=$(tmpfile)
  : > "$tmp_out" 2>/dev/null || true

  local have_lipo="no"
  if is_cmd lipo; then
    have_lipo="yes"
  fi

  # Iterate executables and decide per-file.
  # NOTE: `-perm -111` is used for macOS Bash 3.2 compatibility.
  local root
  for root in "${roots[@]}"; do
    [[ -n "$root" && "$root" == /* && -e "$root" ]] || continue

    while IFS= read -r p; do
      # Defensive: must be a real file.
      [[ -n "$p" && "$p" == /* && -f "$p" ]] || continue

      local archs=""
      local has_x86="no"
      local has_arm="no"

      # Prefer lipo first (much faster than `file` when it works).
      if [[ "$have_lipo" == "yes" ]]; then
        archs=$(lipo -archs "$p" 2>/dev/null || true)
        if [[ -n "$archs" ]]; then
          echo "$archs" | grep -qw "x86_64" && has_x86="yes"
          (echo "$archs" | grep -qw "arm64" || echo "$archs" | grep -qw "arm64e") && has_arm="yes"
        fi
      fi

      # If lipo did not provide arch info, fall back to `file`.
      if [[ -z "$archs" ]]; then
        local fdesc
        fdesc=$(file "$p" 2>/dev/null || true)
        echo "$fdesc" | grep -q "Mach-O" || continue
        echo "$fdesc" | grep -q "x86_64" && has_x86="yes"
        (echo "$fdesc" | grep -q "arm64" || echo "$fdesc" | grep -q "arm64e") && has_arm="yes"
      fi

      # Intel-only means x86_64 present AND no arm slice.
      if [[ "$has_x86" == "yes" && "$has_arm" == "no" ]]; then
        if [[ -n "$archs" ]]; then
          printf "%s: archs=%s\n" "$p" "$archs" >> "$tmp_out" 2>/dev/null || true
        else
          # Keep a stable, one-line-per-file record.
          printf "%s: Intel-only (x86_64)\n" "$p" >> "$tmp_out" 2>/dev/null || true
        fi
      fi
    done < <(find "$root" -type f -perm -111 -print 2>/dev/null)
  done

  # Finalize report: normalize and sort deterministically.
  # Keep one line per file by sorting on the path prefix before ':'
  if [[ -f "$tmp_out" ]]; then
    awk -F':' '/^\// {print $0}' "$tmp_out" 2>/dev/null \
      | sort -t ':' -k1,1 -u \
      > "$out" 2>/dev/null || true
  else
    : > "$out" 2>/dev/null || true
  fi

  # ----------------------------
  # Final counts (authoritative)
  # ----------------------------
  local report_lines=0
  local unique_files=0

  if [[ -f "$out" ]]; then
    report_lines=$(wc -l < "$out" | tr -d ' ')
    unique_files="$report_lines"
  fi

  # Best-effort cleanup
  rm -f "$tmp_out" 2>/dev/null || true

  # ----------------------------
  # Preview: top sources + sample files
  # ----------------------------
  # Present a useful overview instead of the first 10 alphabetically.
  # - First: top sources (apps / roots) by Intel-only file count
  # - Second: a small sample of concrete file paths

  local preview_limit=10

  if [[ "$unique_files" -eq 0 ]]; then
    log "Intel: no x86_64 Mach-O executables found (by heuristics)."
    log "Intel: report written to: $out"
    log "Intel: flagged items: none"
    summary_add "intel" "flagged=0 report=${out}"
    return 0
  fi

  log "Intel: found ${unique_files} Intel-only executable(s) (report lines: ${report_lines})."
  log "Intel: full list written to: $out"

  log "Intel: top sources (top ${preview_limit}):"

  # Guard: awk portability differences exist on macOS; do not fail the whole run if this summary breaks.
  if ! (
    set +o pipefail
    awk -F':' '/^\// {print $1}' "$out" 2>/dev/null \
      | sort -u \
      | awk '
        {
          p=$0
          if (p ~ /^\/Applications\//) {
            n=split(p,a,"/")
            app=""
            for(i=1;i<=n;i++) {
              if (a[i] ~ /\.app$/) { app=a[i]; break }
            }
            if (app != "") { print "Applications/" app; next }
            print "Applications/other"; next
          }
          if (p ~ /^\/Users\//) {
            # POSIX awk compatibility: avoid "+" in regex character classes.
            sub(/^\/Users\/[^\/][^\/]*\//,"/Users/<user>/",p)
            n=split(p,a,"/")
            if (n>=4) { print a[2] "/" a[3] "/" a[4]; next }
            print p; next
          }
          n=split(p,a,"/")
          if (n>=3) { print "/" a[2] "/" a[3]; next }
          print p
        }
      ' \
      | sort \
      | uniq -c \
      | sort -nr \
      | head -n "$preview_limit" \
      | while read -r c src; do
          log "  - ${src}: ${c} file(s)"
        done
  ); then
    log "Intel: top sources summary unavailable (awk error)."
  fi

  log "Intel: sample files (up to ${preview_limit}):"
  awk -F':' '/^\// {print $1}' "$out" 2>/dev/null \
    | sort -u \
    | head -n "$preview_limit" \
    | while IFS= read -r sample; do
        log "  - ${sample}"
      done

  if [[ "$unique_files" -gt "$preview_limit" ]]; then
    log "Intel: (${unique_files} total) See full list for remaining items: $out"
  fi

  # ----------------------------
  # Explain-mode grouping summary
  # ----------------------------
  if [[ "$explain" == "true" && "$unique_files" -gt 0 && -f "$out" ]]; then
    log "Intel (explain): top locations by Intel-only file count (top 10):"

    # Use normalized unique paths so the grouping is stable across `file` output variants.
    awk -F':' '/^\// {print $1}' "$out" \
      | sort -u \
      | awk -F'/' 'NF>2 {print "/"$2"/"$3}' \
      | sort \
      | uniq -c \
      | sort -nr \
      | head -n 10 \
      | while read -r c p; do
          log "  ${c} file(s) under ${p}"
        done
  fi

  # ----------------------------
  # Module end-of-run summary
  # ----------------------------
  if [[ "$unique_files" -eq 0 ]]; then
    summary_add "intel" "flagged=0 report=${out}"
  else
    summary_add "intel" "flagged=${unique_files} report_lines=${report_lines} report=${out}"
  fi
}
