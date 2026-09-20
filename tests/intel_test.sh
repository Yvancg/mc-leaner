#!/bin/bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=tests/test_helper.sh
source "$ROOT_DIR/tests/test_helper.sh"
# shellcheck source=lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=modules/intel.sh
source "$ROOT_DIR/modules/intel.sh"

log() { :; }
summary_add() { :; }
find() { return 0; }

test_default_scan_does_not_touch_desktop_report() {
  local sandbox inventory report
  sandbox="$(mktemp -d -t mcleaner-intel.XXXXXX)" || return 1
  TEST_SANDBOX="$sandbox"
  trap 'rm -rf -- "$TEST_SANDBOX"' EXIT
  HOME="$sandbox/home"
  mkdir -p "$HOME/Desktop" "$HOME/Library"
  report="$HOME/Desktop/intel_binaries.txt"
  printf 'existing user data\n' > "$report"
  inventory="$sandbox/inventory.tsv"
  : > "$inventory"
  INVENTORY_READY="true"
  INVENTORY_INDEX_FILE="$inventory"
  INTEL_REPORT_FILE=""

  run_intel_report "false" || return 1

  assert_eq "existing user data" "$(tr -d '\n' < "$report")" "Desktop report contents" || return 1
  assert_eq "false" "$INTEL_REPORT_WRITTEN" "report written state"
}

test_explicit_report_path_is_written() {
  local sandbox inventory report
  sandbox="$(mktemp -d -t mcleaner-intel.XXXXXX)" || return 1
  TEST_SANDBOX="$sandbox"
  trap 'rm -rf -- "$TEST_SANDBOX"' EXIT
  HOME="$sandbox/home"
  mkdir -p "$HOME/Library"
  inventory="$sandbox/inventory.tsv"
  : > "$inventory"
  report="$sandbox/intel-report.txt"
  INVENTORY_READY="true"
  INVENTORY_INDEX_FILE="$inventory"
  INTEL_REPORT_FILE="$report"

  run_intel_report "false" || return 1

  assert_file_exists "$report" || return 1
  assert_eq "true" "$INTEL_REPORT_WRITTEN" "report written state" || return 1
  assert_eq "$report" "$INTEL_REPORT_PATH" "report output path"
}

test_directory_report_path_is_rejected() {
  local sandbox inventory report
  sandbox="$(mktemp -d -t mcleaner-intel.XXXXXX)" || return 1
  TEST_SANDBOX="$sandbox"
  trap 'rm -rf -- "$TEST_SANDBOX"' EXIT
  HOME="$sandbox/home"
  mkdir -p "$HOME/Library"
  inventory="$sandbox/inventory.tsv"
  : > "$inventory"
  report="$sandbox/report-dir"
  mkdir -p "$report"
  INVENTORY_READY="true"
  INVENTORY_INDEX_FILE="$inventory"
  INTEL_REPORT_FILE="$report"

  if run_intel_report "false"; then
    return 1
  fi
  assert_eq "false" "$INTEL_REPORT_WRITTEN" "report written state"
}

run_test "default Intel scan preserves Desktop report" test_default_scan_does_not_touch_desktop_report
run_test "explicit Intel report path is written" test_explicit_report_path_is_written
run_test "directory Intel report path is rejected" test_directory_report_path_is_rejected
finish_tests
