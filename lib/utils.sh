#!/bin/bash
# mc-leaner: shared utilities
# Purpose: Provide small, reusable helpers for logging, command detection, and temporary file creation
# Safety: Pure helper functions; no file moves, no privilege escalation, no destructive operations

set -euo pipefail

# ----------------------------
# Logging
# ----------------------------
ts() { date +"%Y-%m-%d %H:%M:%S"; }
log() { printf "[%s] %s\n" "$(ts)" "$*"; }

# ----------------------------
# Environment checks
# ----------------------------
is_cmd() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------
# Temporary files
# ----------------------------
tmpfile() {
  # Purpose: create a unique temp file path compatible with macOS Bash 3.2
  mktemp "/tmp/mc-leaner.XXXXXX"
}

# End of library
