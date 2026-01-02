#!/bin/bash
# mc-leaner: user interaction helpers
# Purpose: Provide a minimal, auditable prompting layer with GUI-first behavior and a terminal fallback
# Safety: All prompts are explicit; no silent approvals; cancellation defaults to no action

set -euo pipefail

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
