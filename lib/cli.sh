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
EXPLAIN="false"

# ----------------------------
# Help text
# ----------------------------

usage() {
  cat <<'EOF'
mc-leaner

Usage:
  bash mc-leaner.sh [--mode <scan|clean|report|inventory-only|launchd-only|bins-only|caches-only|logs-only|brew-only|leftovers-only|permissions-only>] [--apply] [--backup-dir <path>] [--explain]

Defaults:
  --mode scan     (dry-run, no moves)
  --apply         required for any move

Options:
  --explain              Show why items are skipped or flagged (verbose; inspection-only)

Examples:
  bash mc-leaner.sh
  bash mc-leaner.sh --mode clean --apply
  bash mc-leaner.sh --mode report
  bash mc-leaner.sh --mode inventory-only
  bash mc-leaner.sh --mode caches-only
  bash mc-leaner.sh --mode logs-only
  bash mc-leaner.sh --mode brew-only
  bash mc-leaner.sh --mode leftovers-only
  bash mc-leaner.sh --mode permissions-only
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
      --explain) EXPLAIN="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      # Fail closed: unknown flags are rejected to avoid unintended behavior
      *) echo "Unknown arg: $1"; usage; exit 1 ;;
    esac
  done

  validate_mode
}

validate_mode() {
  case "$MODE" in
    scan|clean|report|inventory-only|launchd-only|bins-only|caches-only|logs-only|brew-only|leftovers-only|permissions-only)
      return 0
      ;;
    *)
      echo "Invalid --mode: $MODE"
      usage
      exit 1
      ;;
  esac
}

# End of library