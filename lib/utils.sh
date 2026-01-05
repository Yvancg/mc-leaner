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

# Explain logging (only when --explain is enabled)
explain_log() {
  # Purpose: emit verbose reasoning only when EXPLAIN=true
  # Safety: logging only
  if [ "${EXPLAIN:-false}" = "true" ]; then
    log "EXPLAIN: $*"
  fi
}

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

# ----------------------------
# Run summary (collector)
# ----------------------------
# Purpose: allow modules to register end-of-run summary lines; printed once by the entrypoint
# Safety: logging only

# Bash 3.2 compatibility: initialize arrays defensively under set -u
#
# Legacy/freeform summary lines (kept for backward compatibility)
declare -a SUMMARY_LINES
SUMMARY_LINES=()

# Structured summary lines (recommended)
declare -a SUMMARY_MODULE_LINES
declare -a SUMMARY_ACTION_LINES
declare -a SUMMARY_INFO_LINES
SUMMARY_MODULE_LINES=()
SUMMARY_ACTION_LINES=()
SUMMARY_INFO_LINES=()

summary__ensure_arrays() {
  # Purpose: ensure summary arrays exist even if unset by a caller
  # Safety: logging only
  # Notes: required for Bash 3.2 + `set -u` (avoids unbound variable errors)

  if ! declare -p SUMMARY_LINES >/dev/null 2>&1; then
    declare -a SUMMARY_LINES
    SUMMARY_LINES=()
  fi

  if ! declare -p SUMMARY_MODULE_LINES >/dev/null 2>&1; then
    declare -a SUMMARY_MODULE_LINES
    SUMMARY_MODULE_LINES=()
  fi

  if ! declare -p SUMMARY_ACTION_LINES >/dev/null 2>&1; then
    declare -a SUMMARY_ACTION_LINES
    SUMMARY_ACTION_LINES=()
  fi

  if ! declare -p SUMMARY_INFO_LINES >/dev/null 2>&1; then
    declare -a SUMMARY_INFO_LINES
    SUMMARY_INFO_LINES=()
  fi
}

summary_add() {
  # Usage (legacy): summary_add "Module: flagged 2; moved 1; failures 0"
  # Purpose: allow older modules to register a human-readable summary line
  # Safety: logging only
  summary__ensure_arrays
  SUMMARY_LINES+=("$*")
}

summary_add_module_line() {
  # Usage: summary_add_module_line "caches scanned_dirs=88 total_mb=599 | flagged=1 | moved=no"
  # Purpose: register a single, parseable module line for the consolidated summary
  # Safety: logging only
  summary__ensure_arrays
  SUMMARY_MODULE_LINES+=("$*")
}

summary_add_action() {
  # Usage: summary_add_action "caches: 1 item(s) above threshold (review before moving)"
  # Purpose: register an action-required line (things that likely need user attention)
  # Safety: logging only
  summary__ensure_arrays
  SUMMARY_ACTION_LINES+=("$*")
}

summary_add_info() {
  # Usage: summary_add_info "intel: report written to /Users/yvan/Desktop/intel_binaries.txt"
  # Purpose: register an informational line (non-actionable outputs)
  # Safety: logging only
  summary__ensure_arrays
  SUMMARY_INFO_LINES+=("$*")
}

summary_print() {
  # Purpose: print consolidated summary at end of run

  summary__ensure_arrays

  local module_count=${#SUMMARY_MODULE_LINES[@]}
  local legacy_count=${#SUMMARY_LINES[@]}
  local action_count=${#SUMMARY_ACTION_LINES[@]}
  local info_count=${#SUMMARY_INFO_LINES[@]}

  if [ "$module_count" -eq 0 ] && [ "$legacy_count" -eq 0 ] && [ "$action_count" -eq 0 ] && [ "$info_count" -eq 0 ]; then
    return 0
  fi

  log "RUN SUMMARY:"

  local line

  if [ "$module_count" -gt 0 ]; then
    for line in "${SUMMARY_MODULE_LINES[@]}"; do
      log "  - $line"
    done
  fi

  # Print legacy/freeform lines after structured lines (if any)
  if [ "$legacy_count" -gt 0 ]; then
    for line in "${SUMMARY_LINES[@]}"; do
      log "  - $line"
    done
  fi

  if [ "$action_count" -gt 0 ]; then
    log ""
    log "ACTION REQUIRED:"
    for line in "${SUMMARY_ACTION_LINES[@]}"; do
      log "  - $line"
    done
  fi

  if [ "$info_count" -gt 0 ]; then
    log ""
    log "INFO ONLY:"
    for line in "${SUMMARY_INFO_LINES[@]}"; do
      log "  - $line"
    done
  fi
}
