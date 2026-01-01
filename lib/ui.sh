#!/bin/bash
set -euo pipefail

# UI: prefer GUI prompt (osascript), fallback to terminal prompt.
ask_yes_no() {
  local msg="$1"

  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'display dialog "'"$msg"'" buttons {"Cancel", "OK"} default button "OK"' \
      >/dev/null 2>&1
    return $?
  fi

  printf "%s [y/N]: " "$msg"
  read -r ans || true
  [[ "${ans:-}" =~ ^[Yy]$ ]]
}
