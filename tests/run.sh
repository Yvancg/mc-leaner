#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
status=0

for test_file in "$ROOT_DIR"/tests/*_test.sh; do
  [[ -f "$test_file" ]] || continue
  printf '\n%s\n' "==> ${test_file##*/}"
  if ! /bin/bash "$test_file"; then
    status=1
  fi
done

exit "$status"
