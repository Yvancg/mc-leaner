#!/bin/bash

TEST_FAILURES=0
TEST_COUNT=0

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="${3:-values differ}"

  if [[ "$expected" != "$actual" ]]; then
    printf '    %s: expected <%s>, got <%s>\n' "$message" "$expected" "$actual" >&2
    return 1
  fi
}

assert_file_exists() {
  local path="$1"
  [[ -e "$path" || -L "$path" ]] || {
    printf '    expected path to exist: %s\n' "$path" >&2
    return 1
  }
}

assert_file_not_exists() {
  local path="$1"
  [[ ! -e "$path" && ! -L "$path" ]] || {
    printf '    expected path not to exist: %s\n' "$path" >&2
    return 1
  }
}

run_test() {
  local name="$1"
  shift
  TEST_COUNT=$((TEST_COUNT + 1))

  if ("$@"); then
    printf 'ok %s - %s\n' "$TEST_COUNT" "$name"
  else
    printf 'not ok %s - %s\n' "$TEST_COUNT" "$name"
    TEST_FAILURES=$((TEST_FAILURES + 1))
  fi
}

finish_tests() {
  if [[ "$TEST_FAILURES" -ne 0 ]]; then
    printf '%s of %s tests failed\n' "$TEST_FAILURES" "$TEST_COUNT" >&2
    return 1
  fi

  printf '%s tests passed\n' "$TEST_COUNT"
}
