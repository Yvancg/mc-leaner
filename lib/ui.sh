#!/bin/bash
# mc-leaner: user interaction helpers
# Purpose: Provide a minimal, auditable prompting layer with GUI-first behavior and a terminal fallback
# Safety: All prompts are explicit; no silent approvals; cancellation defaults to no action

# NOTE: Libraries must not set shell options like `set -e`/`set -u`.
# mc-leaner.sh owns shell strictness.

# ----------------------------
# Logging helpers (shared contract)
# ----------------------------

# Purpose: Print a timestamped log line
# Output format: [YYYY-MM-DD HH:MM:SS] <message>
log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] %s\n' "$ts" "$*"
}

# Purpose: Print an EXPLAIN log line when explain mode is enabled
# Behavior:
# - If `EXPLAIN=true`, prints to stdout
# - Otherwise, no output
explain_log() {
  [[ "${EXPLAIN:-false}" == "true" ]] || return 0
  printf 'EXPLAIN: %s\n' "$*"
}

# Compatibility aliases (modules may call these)
log_info()  { log "$@"; }
log_warn()  { log "$@"; }
log_error() { log "$@"; }

# Purpose: Log an error message and exit non-zero
# Usage: die "message" [exit_code]
die() {
  local msg="${1:-}"; local code="${2:-1}"
  log_error "$msg"
  exit "$code"
}

# ----------------------------
# Confirmation prompts
# ----------------------------

# Purpose: Ask the user to confirm an action
# Behavior:
# - Uses a GUI dialog when `osascript` is available
# - Falls back to a terminal prompt otherwise
# - Returns success (0) only on explicit confirmation
ask_yes_no() {
  local msg="$1"

  # Prefer GUI prompts for clarity and to reduce accidental approvals
  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'display dialog "'"$msg"'" buttons {"Cancel", "OK"} default button "OK"' \
      >/dev/null 2>&1
    return $?
  fi

  # Terminal fallback: default to "No" on empty input
  printf "%s [y/N]: " "$msg"
  read -r ans || true
  [[ "${ans:-}" =~ ^[Yy]$ ]]
}

# End of library
