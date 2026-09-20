#!/bin/bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=tests/test_helper.sh
source "$ROOT_DIR/tests/test_helper.sh"

test_missing_option_value_is_usage_error() {
  local output rc
  output="$(/bin/bash "$ROOT_DIR/mc-leaner.sh" --mode 2>&1)"
  rc=$?
  assert_eq "2" "$rc" "exit status" || return 1
  case "$output" in
    *"--mode requires a value"*) return 0 ;;
    *) return 1 ;;
  esac
}

test_following_option_is_not_consumed_as_value() {
  local output rc
  output="$(/bin/bash "$ROOT_DIR/mc-leaner.sh" --intel-report --quiet 2>&1)"
  rc=$?
  assert_eq "2" "$rc" "exit status" || return 1
  case "$output" in
    *"--intel-report requires a value"*) return 0 ;;
    *) return 1 ;;
  esac
}

run_test "missing option value returns usage error" test_missing_option_value_is_usage_error
run_test "an option is not consumed as another option's value" test_following_option_is_not_consumed_as_value
finish_tests
