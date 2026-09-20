#!/bin/bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=tests/test_helper.sh
source "$ROOT_DIR/tests/test_helper.sh"
# shellcheck source=lib/ui.sh
source "$ROOT_DIR/lib/ui.sh"

test_terminal_eof_declines() {
  GUI_PROMPTS="false"
  UI_TTY_PATH="/path/that/does/not/exist"
  if ask_yes_no "Test prompt" </dev/null 2>/dev/null; then
    return 1
  fi
}

test_gui_dialog_defaults_to_cancel() {
  GUI_PROMPTS="true"
  local args_file
  args_file="$(mktemp -t mcleaner-ui.XXXXXX)" || return 1
  TEST_ARGS_FILE="$args_file"
  trap 'rm -f -- "$TEST_ARGS_FILE"' EXIT

  osascript() {
    printf '%s\n' "$*" > "$args_file"
    return 1
  }

  if ask_yes_no "Test prompt"; then
    return 1
  fi

  grep -Fq 'default button "Cancel"' "$args_file"
}

run_test "terminal EOF declines confirmation" test_terminal_eof_declines
run_test "GUI confirmation defaults to Cancel" test_gui_dialog_defaults_to_cancel
finish_tests
