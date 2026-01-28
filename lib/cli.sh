#!/bin/bash
# mc-leaner: CLI parsing utilities
# Purpose: Define supported flags, defaults, and help output for the mc-leaner entry point
# Safety: Enforces explicit opt-in for any cleanup action via `--apply`; defaults to dry-run mode

# ----------------------------
# Defaults
# ----------------------------

MODE="scan"
APPLY="false"
BACKUP_DIR=""
ONLY_MODULE=""  # Reserved for future module-level selection
EXPLAIN="false"

# Supported modes are declared once to avoid drift between help text and validation.
SUPPORTED_MODES=(
  scan
  clean
  report
  inventory-only
  launchd-only
  startup-only
  bins-only
  caches-only
  logs-only
  brew-only
  leftovers-only
  permissions-only
  disk-only
)

# ----------------------------
# Help Text
# ----------------------------

usage() {
  cat <<EOF
mc-leaner — inspection-first system hygiene with explicit run summaries

Usage:
  bash mc-leaner.sh [--mode <mode>] [--apply] [--backup-dir <path>] [--explain]

Modes:
  $(printf '%s' "${SUPPORTED_MODES[*]}" | tr ' ' '|')

Defaults:
  --mode scan     (inspection-only; no moves)
  --apply         required for any move

Notes:
  - All inspection modes list every flagged item in the end-of-run summary
  - Counts are always paired with explicit identifiers

Options:
  --explain       Show why items are skipped or flagged (verbose; allowed in all modes)

Examples:
  bash mc-leaner.sh
  bash mc-leaner.sh --mode clean --apply
  bash mc-leaner.sh --mode report
  bash mc-leaner.sh --mode inventory-only
  bash mc-leaner.sh --mode startup-only
  bash mc-leaner.sh --mode disk-only
  bash mc-leaner.sh --mode caches-only
  bash mc-leaner.sh --mode logs-only
  bash mc-leaner.sh --mode brew-only
  bash mc-leaner.sh --mode leftovers-only
  bash mc-leaner.sh --mode permissions-only
EOF
}

# ----------------------------
# Argument Parsing
# ----------------------------

parse_args() {
  # Fail-closed CLI parsing: accept only known flags to avoid unintended behavior
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) MODE="${2:-}"; shift 2 ;;
      --apply) APPLY="true"; shift ;;
      --backup-dir) BACKUP_DIR="${2:-}"; shift 2 ;;
      --explain) EXPLAIN="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      # SAFETY: reject unknown flags to prevent accidental mode or apply changes
      *) echo "Unknown arg: $1"; usage; exit 1 ;;
    esac
  done

  # SAFETY: validate mode against the declared supported list (prevents drift and typos)
  validate_mode
}

validate_mode() {
  # Validate --mode strictly against SUPPORTED_MODES (single source of truth)
  local m
  for m in "${SUPPORTED_MODES[@]}"; do
    if [[ "$MODE" == "$m" ]]; then
      return 0
    fi
  done

  echo "Invalid --mode: $MODE"
  usage
  exit 1
}

# End of library