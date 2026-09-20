#!/bin/bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=tests/test_helper.sh
source "$ROOT_DIR/tests/test_helper.sh"
# shellcheck source=lib/fs.sh
source "$ROOT_DIR/lib/fs.sh"
# shellcheck source=lib/safety.sh
source "$ROOT_DIR/lib/safety.sh"

test_duplicate_basenames_get_distinct_destinations() {
  local sandbox backup src_a src_b dest_a dest_b
  sandbox="$(mktemp -d -t mcleaner-fs.XXXXXX)" || return 1
  TEST_SANDBOX="$sandbox"
  trap 'rm -rf -- "$TEST_SANDBOX"' EXIT
  backup="$sandbox/backup"
  src_a="$sandbox/a/shared.log"
  src_b="$sandbox/b/shared.log"
  mkdir -p "$(dirname "$src_a")" "$(dirname "$src_b")"
  printf 'first\n' > "$src_a"
  printf 'second\n' > "$src_b"

  move_attempt "$src_a" "$backup" || return 1
  dest_a="$MOVE_LAST_DEST"
  move_attempt "$src_b" "$backup" || return 1
  dest_b="$MOVE_LAST_DEST"

  [[ "$dest_a" != "$dest_b" ]] || return 1
  assert_eq "first" "$(tr -d '\n' < "$dest_a")" "first payload" || return 1
  assert_eq "second" "$(tr -d '\n' < "$dest_b")" "second payload" || return 1
  backup_manifest_checksum_verify "$backup"
}

test_manifest_failure_rolls_back_move() {
  local sandbox backup src
  sandbox="$(mktemp -d -t mcleaner-fs.XXXXXX)" || return 1
  TEST_SANDBOX="$sandbox"
  trap 'rm -rf -- "$TEST_SANDBOX"' EXIT
  backup="$sandbox/backup"
  src="$sandbox/source.txt"
  printf 'keep me\n' > "$src"

  backup_manifest_append() { return 1; }

  if move_attempt "$src" "$backup"; then
    return 1
  fi

  assert_file_exists "$src" || return 1
  assert_eq "keep me" "$(tr -d '\n' < "$src")" "rolled back payload" || return 1
  assert_eq "manifest" "$MOVE_LAST_CODE" "failure classification"
}

test_protected_path_is_never_moved() {
  local sandbox backup src
  sandbox="$(mktemp -d -t mcleaner-fs.XXXXXX)" || return 1
  TEST_SANDBOX="$sandbox"
  trap 'rm -rf -- "$TEST_SANDBOX"' EXIT
  backup="$sandbox/backup"
  src="$sandbox/COM.MALWAREBYTES.Agent"
  printf 'protected\n' > "$src"

  if move_attempt "$src" "$backup"; then
    return 1
  fi

  assert_file_exists "$src" || return 1
  assert_eq "protected" "$MOVE_LAST_CODE" "protected classification"
}

test_restore_refuses_dangling_symlink_target() {
  local sandbox payload target
  sandbox="$(mktemp -d -t mcleaner-fs.XXXXXX)" || return 1
  TEST_SANDBOX="$sandbox"
  trap 'rm -rf -- "$TEST_SANDBOX"' EXIT
  payload="$sandbox/payload"
  target="$sandbox/target"
  printf 'payload\n' > "$payload"
  ln -s "$sandbox/missing" "$target"

  if safe_restore "$payload" "$target" >/dev/null 2>&1; then
    return 1
  fi

  assert_file_exists "$payload" || return 1
  [[ -L "$target" ]]
}

test_system_launchd_and_log_paths_are_report_only() {
  local sandbox
  sandbox="$(mktemp -d -t mcleaner-fs.XXXXXX)" || return 1
  TEST_SANDBOX="$sandbox"
  trap 'rm -rf -- "$TEST_SANDBOX"' EXIT

  is_report_only_system_path "/Library/LaunchAgents" || return 1
  is_report_only_system_path "/library/launchagents/com.example.test.plist" || return 1
  is_report_only_system_path "/System/Volumes/Data/Library/Logs/example.log" || return 1
  is_report_only_system_path "/Library/LaunchDaemons/com.example.test.plist" || return 1
  is_report_only_system_path "/Library/Logs/example.log" || return 1
  is_report_only_system_path "/var/log/example.log" || return 1
  ln -s /var/log "$sandbox/log-link"
  is_report_only_system_path "$sandbox/log-link/example.log" || return 1
  if is_report_only_system_path "$HOME/Library/Logs/example.log"; then
    return 1
  fi
}

test_parallel_moves_preserve_all_manifest_entries() {
  local sandbox backup i pid records payloads workers
  local -a pids
  sandbox="$(mktemp -d -t mcleaner-fs.XXXXXX)" || return 1
  TEST_SANDBOX="$sandbox"
  trap 'rm -rf -- "$TEST_SANDBOX"' EXIT
  backup="$sandbox/backup"
  workers=24
  pids=()

  i=1
  while [[ "$i" -le "$workers" ]]; do
    mkdir -p "$sandbox/src-$i"
    printf '%s\n' "$i" > "$sandbox/src-$i/item.txt"
    (move_attempt "$sandbox/src-$i/item.txt" "$backup") &
    pids+=("$!")
    i=$((i + 1))
  done

  for pid in "${pids[@]}"; do
    wait "$pid" || return 1
  done

  records="$(awk -F '\t' '$1 !~ /^#/ && NF == 3 {count++} END {print count+0}' "$backup/.mcleaner_manifest.tsv")"
  payloads=0
  for payload in "$backup"/.mcleaner-item.*/*; do
    [[ -e "$payload" || -L "$payload" ]] || continue
    payloads=$((payloads + 1))
  done
  assert_eq "$workers" "$records" "manifest records" || return 1
  assert_eq "$workers" "$payloads" "backup payloads" || return 1
  backup_manifest_checksum_verify "$backup"
}

test_abandoned_manifest_lock_fails_closed() {
  local sandbox backup src
  sandbox="$(mktemp -d -t mcleaner-fs.XXXXXX)" || return 1
  TEST_SANDBOX="$sandbox"
  trap 'rm -rf -- "$TEST_SANDBOX"' EXIT
  backup="$sandbox/backup"
  src="$sandbox/source.txt"
  mkdir -p "$backup/.mcleaner-manifest.lock"
  printf '999999\tstale\n' > "$backup/.mcleaner-manifest.lock/pid"
  printf 'payload\n' > "$src"
  MCLEANER_LOCK_ATTEMPTS=2

  if move_attempt "$src" "$backup"; then
    return 1
  fi
  assert_file_exists "$src" || return 1
  assert_eq "manifest" "$MOVE_LAST_CODE" "failure classification"
}

test_cli_restores_dangling_symlink_payload() {
  local sandbox backup src output rc
  sandbox="$(mktemp -d -t mcleaner-fs.XXXXXX)" || return 1
  TEST_SANDBOX="$sandbox"
  trap 'rm -rf -- "$TEST_SANDBOX"' EXIT
  mkdir -p "$sandbox/home"
  backup="$sandbox/backup"
  src="$sandbox/dangling-link"
  ln -s "$sandbox/missing-target" "$src"

  move_attempt "$src" "$backup" || return 1
  assert_file_not_exists "$src" || return 1

  output="$(printf 'y\n' | HOME="$sandbox/home" UI_TTY_PATH="$sandbox/no-tty" /bin/bash "$ROOT_DIR/mc-leaner.sh" --restore-backup "$backup" --no-gui 2>&1)"
  rc=$?
  assert_eq "0" "$rc" "restore exit status" || {
    printf '    restore output: %s\n' "$output" >&2
    return 1
  }
  [[ -L "$src" ]] || {
    printf '    restore output: %s\n' "$output" >&2
    return 1
  }
  assert_eq "$sandbox/missing-target" "$(readlink "$src")" "symlink target"
}

test_verify_fails_when_payload_is_missing() {
  local sandbox backup src displaced output rc
  sandbox="$(mktemp -d -t mcleaner-fs.XXXXXX)" || return 1
  TEST_SANDBOX="$sandbox"
  trap 'rm -rf -- "$TEST_SANDBOX"' EXIT
  mkdir -p "$sandbox/home"
  backup="$sandbox/backup"
  src="$sandbox/source.txt"
  displaced="$sandbox/displaced.txt"
  printf 'payload\n' > "$src"

  move_attempt "$src" "$backup" || return 1
  /bin/mv "$MOVE_LAST_DEST" "$displaced"

  output="$(HOME="$sandbox/home" /bin/bash "$ROOT_DIR/mc-leaner.sh" --verify-backup "$backup" --no-gui 2>&1)"
  rc=$?
  assert_eq "5" "$rc" "verify exit status" || {
    printf '    verify output: %s\n' "$output" >&2
    return 1
  }
}

run_test "duplicate basenames use distinct backup destinations" test_duplicate_basenames_get_distinct_destinations
run_test "manifest failure rolls back the source" test_manifest_failure_rolls_back_move
run_test "protected paths are rejected centrally" test_protected_path_is_never_moved
run_test "restore refuses dangling symlink targets" test_restore_refuses_dangling_symlink_target
run_test "system launchd and log paths are report-only" test_system_launchd_and_log_paths_are_report_only
run_test "parallel moves preserve every manifest entry" test_parallel_moves_preserve_all_manifest_entries
run_test "abandoned manifest lock fails closed" test_abandoned_manifest_lock_fails_closed
run_test "CLI restores a dangling symlink payload" test_cli_restores_dangling_symlink_payload
run_test "backup verification fails for missing payloads" test_verify_fails_when_payload_is_missing
finish_tests
