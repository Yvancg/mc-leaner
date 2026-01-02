#!/bin/bash
# mc-leaner: Intel-only executable reporting module
# Purpose: Identify Intel-only (x86_64) Mach-O executables for visibility on Apple Silicon systems
# Safety: Reporting-only; never modifies, moves, or deletes files

set -euo pipefail

# ----------------------------
# Module entry point
# ----------------------------

run_intel_report() {
  # ----------------------------
  # Report destination
  # ----------------------------
  local out="$HOME/Desktop/intel_binaries.txt"

  log "Scanning for Intel-only executables (informational)..."
  # NOTE:
  # - Uses `-perm +111` for macOS compatibility (deprecated elsewhere but reliable here)
  # - Errors are suppressed intentionally to avoid noise from protected paths
  # - This scan is informational only and has no side effects

  # ----------------------------
  # Intel-only executable scan
  # ----------------------------
  find /Applications "$HOME/Applications" "$HOME/Library" /opt -type f -perm +111 -exec file {} + 2>/dev/null \
    | grep "Mach-O 64-bit executable x86_64" > "$out" 2>/dev/null || true
  log "Intel-only executables listed at: $out"
}

# End of module
