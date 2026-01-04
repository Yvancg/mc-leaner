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
  local count=0
  if [[ -f "$out" ]]; then
    count=$(wc -l < "$out" | tr -d ' ' || echo 0)
  fi

  # ----------------------------
  # Flagged item preview (end-of-run summary)
  # ----------------------------
  # We treat Intel-only executables as "flagged for review".
  # This module never changes the system; it only reports findings.
  local -a flagged_items=()
  local preview_limit=10

  if [[ -f "$out" && "$count" -gt 0 ]]; then
    # `file` output format: /path/to/file: Mach-O ...
    # Extract just the path prefix for human-readable preview.
    while IFS= read -r p; do
      [[ -n "$p" ]] && flagged_items+=("$p")
    done < <(awk -F':' '{print $1}' "$out" 2>/dev/null | head -n "$preview_limit")
  fi

  if [[ "$count" -eq 0 ]]; then
    log "Intel: no Intel-only executables found (by heuristics)."
    log "Intel: report written to: $out"
    log "Intel: flagged items: none"
    return 0
  fi

  log "Intel: found ${count} Intel-only executable(s)."
  log "Intel: full list written to: $out"

  log "Intel: flagged items (preview, top ${preview_limit}):"
  if [[ "${#flagged_items[@]}" -eq 0 ]]; then
    log "  (none)"
  else
    local i
    for i in "${flagged_items[@]}"; do
      log "  - ${i}"
    done
    if [[ "$count" -gt "$preview_limit" ]]; then
      log "Intel: (${count} total) See full list for remaining items: $out"
    fi
  fi

  # ----------------------------
  # Explain-mode grouping summary
  # ----------------------------
  if [[ "$explain" == "true" && "$count" -gt 0 && -f "$out" ]]; then
    log "Intel (explain): top locations by count (top 10):"
    awk -F':' '{print $1}' "$out" \
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
  if [[ "$count" -eq 0 ]]; then
    summary_add "intel" "flagged=0 report=${out}"
  else
    summary_add "intel" "flagged=${count} report=${out}"
  fi
}
