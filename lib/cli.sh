#!/bin/bash
# mc-leaner: CLI parsing utilities
# Purpose: Define supported flags, defaults, and help output for the mc-leaner entry point
# Safety: Enforces explicit opt-in for any cleanup action via `--apply`; defaults to dry-run mode

set -euo pipefail

# ----------------------------
# Defaults
# ----------------------------

MODE="scan"
APPLY="false"
BACKUP_DIR=""
ONLY_MODULE=""  # Reserved for future module-level selection

# ----------------------------
# Help text
# ----------------------------

usage() {
  cat <<'EOF'
mc-leaner

Usage:
  bash mc-leaner.sh [--mode <scan|clean|report|launchd-only|bins-only>] [--apply] [--backup-dir <path>]

Defaults:
  --mode scan     (dry-run, no moves)
  --apply         required for any move

Examples:
  bash mc-leaner.sh
  bash mc-leaner.sh --mode clean --apply
  bash mc-leaner.sh --mode report
EOF
}

# ----------------------------
# Argument parsing
# ----------------------------

parse_args() {
  # Parse recognized flags and fail fast on unknown arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) MODE="${2:-}"; shift 2 ;;
      --apply) APPLY="true"; shift ;;
      --backup-dir) BACKUP_DIR="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      # Fail closed: unknown flags are rejected to avoid unintended behavior
      *) echo "Unknown arg: $1"; usage; exit 1 ;;
    esac
  done
}

# End of library