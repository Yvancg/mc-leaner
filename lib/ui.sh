#!/bin/bash
# mc-leaner: user interaction helpers
# Purpose: Provide a minimal, auditable prompting layer with GUI-first behavior and a terminal fallback
# Safety: All prompts are explicit; no silent approvals; cancellation defaults to no action

# NOTE: Libraries must not set shell options like `set -e`/`set -u`.
# mc-leaner.sh owns shell strictness.

# Logging primitives are provided by .lib/utils.sh (log, explain_log, die).
# ui.sh focuses only on interactive prompting.

# ----------------------------
# Confirmation prompts
# ----------------------------

#
# Purpose: Ask the user to explicitly confirm an action.
# Behavior:
# - Prefers a GUI dialog for clarity when available.
# - Falls back to a terminal prompt when GUI is unavailable.
# Safety:
# - No silent approvals.
# - Cancellation and empty input default to "No".
# - Returns success (0) only on explicit confirmation.
ask_yes_no() {
  local msg="$1"

  # Prefer GUI prompts for clarity and to reduce accidental approvals
  if command -v osascript >/dev/null 2>&1; then
    # SAFETY: pass the message as an argument to avoid quote/escape issues.
    osascript \
      -e 'on run argv' \
      -e 'display dialog (item 1 of argv) buttons {"Cancel", "OK"} default button "OK"' \
      -e 'end run' \
      -- "$msg" \
      >/dev/null 2>&1
    return $?
  fi

  # Terminal fallback: default to "No" on empty input
  printf "%s [y/N]: " "$msg"
  # SAFETY: treat read failures (EOF) as "No" and continue deterministically.
  read -r ans || true
  [[ "${ans:-}" =~ ^[Yy]$ ]]
}

# End of library
