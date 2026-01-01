#!/bin/bash
set -euo pipefail

run_intel_report() {
  local out="$HOME/Desktop/intel_binaries.txt"
  log "Scanning for Intel-only executables (informational)..."
  # Note: -perm +111 is legacy but works on macOS find; keep conservative with errors suppressed.
  find /Applications "$HOME/Applications" "$HOME/Library" /opt -type f -perm +111 -exec file {} + 2>/dev/null \
    | grep "Mach-O 64-bit executable x86_64" > "$out" 2>/dev/null || true
  log "Intel-only executables listed at: $out"
}
