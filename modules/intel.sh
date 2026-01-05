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

  # ----------------------------
  # Report destination
  # ----------------------------
  local out="$HOME/Desktop/intel_binaries.txt"

  # ----------------------------
  # Scan roots
  # ----------------------------
  local roots=(
    "/Applications"
    "$HOME/Applications"
    "$HOME/Library"
    "/opt"
  )

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
  find "${roots[@]}" -type f -perm +111 -exec file {} + 2>/dev/null \
    | grep "Mach-O 64-bit executable x86_64" > "$out" 2>/dev/null || true

  # ----------------------------
  # Summary
  # ----------------------------
  # NOTE:
  # - The report can contain multiple lines per executable (for example, a universal header line
  #   plus an architecture-specific line like "(for architecture x86_64)").
  # - For stable reporting, we compute BOTH:
  #   - report_lines: raw lines written to the report (debug metric)
  #   - unique_files: normalized unique paths (stable metric)

  local report_lines=0
  local unique_files=0

  if [[ -f "$out" ]]; then
    report_lines=$(wc -l < "$out" | tr -d ' ' || echo 0)

    # `file` output format: /path/to/file: Mach-O ...
    # Normalize paths by removing the architecture suffix emitted by `file`.
    unique_files=$(
      awk -F':' '{print $1}' "$out" 2>/dev/null \
        | sed 's/ (for architecture x86_64)$//' \
        | sort -u \
        | wc -l \
        | tr -d ' ' || echo 0
    )
  fi

  # ----------------------------
  # Flagged item preview (end-of-run summary)
  # ----------------------------
  # We treat Intel-only executables as "flagged for review".
  # This module never changes the system; it only reports findings.
  local -a flagged_items=()
  local preview_limit=10

  if [[ -f "$out" && "$unique_files" -gt 0 ]]; then
    # `file` output format: /path/to/file: Mach-O ...
    # Extract and normalize paths for a stable human-readable preview.
    while IFS= read -r p; do
      [[ -n "$p" ]] && flagged_items+=("$p")
    done < <(
      awk -F':' '{print $1}' "$out" 2>/dev/null \
        | sed 's/ (for architecture x86_64)$//' \
        | sort -u \
        | head -n "$preview_limit"
    )
  fi

  if [[ "$unique_files" -eq 0 ]]; then
    log "Intel: no x86_64 Mach-O executables found (by heuristics)."
    log "Intel: report written to: $out"
    log "Intel: flagged items: none"
    return 0
  fi

  log "Intel: found ${unique_files} executable(s) with an x86_64 slice (report lines: ${report_lines})."
  log "Intel: full list written to: $out"

  log "Intel: flagged items (preview, top ${preview_limit}):"
  if [[ "${#flagged_items[@]}" -eq 0 ]]; then
    log "  (none)"
  else
    local i
    for i in "${flagged_items[@]}"; do
      log "  - ${i}"
    done
    if [[ "$unique_files" -gt "$preview_limit" ]]; then
      log "Intel: (${unique_files} total) See full list for remaining items: $out"
    fi
  fi

  # ----------------------------
  # Explain-mode grouping summary
  # ----------------------------
  if [[ "$explain" == "true" && "$unique_files" -gt 0 && -f "$out" ]]; then
    log "Intel (explain): top locations by unique file count (top 10):"

    # Use normalized unique paths so the grouping is stable across `file` output variants.
    awk -F':' '{print $1}' "$out" \
      | sed 's/ (for architecture x86_64)$//' \
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
