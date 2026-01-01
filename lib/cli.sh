#!/bin/bash
set -euo pipefail

MODE="scan"
APPLY="false"
BACKUP_DIR=""
ONLY_MODULE=""

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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) MODE="${2:-}"; shift 2 ;;
      --apply) APPLY="true"; shift ;;
      --backup-dir) BACKUP_DIR="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown arg: $1"; usage; exit 1 ;;
    esac
  done
}
