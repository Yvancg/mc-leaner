#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd -P)"
cd "$root"

if ! command -v shellcheck >/dev/null 2>&1; then
  if [[ "${CI:-}" == "true" || "${CI:-}" == "1" ]]; then
    if command -v brew >/dev/null 2>&1; then
      brew install shellcheck
    else
      echo "shellcheck not found" >&2
      exit 4
    fi
  else
    echo "shellcheck not found (install it or run with CI=1)" >&2
    exit 4
  fi
fi

shellcheck -x -e SC1091,SC2034,SC2329 mc-leaner.sh lib/*.sh modules/*.sh

expected_version="$(head -n 1 VERSION 2>/dev/null | tr -d '[:space:]')"
actual_version="$(bash mc-leaner.sh --version | tr -d '[:space:]')"
if [[ -z "$expected_version" || "$actual_version" != "$expected_version" ]]; then
  echo "version mismatch: expected=$expected_version actual=$actual_version" >&2
  exit 6
fi

tmp_json="$(mktemp -t mcleaner.json.XXXXXX)"
cleanup() { rm -f "$tmp_json" 2>/dev/null || true; }
trap cleanup EXIT

bash mc-leaner.sh --mode permissions-only --json-file "$tmp_json" --no-gui --quiet

TMP_JSON="$tmp_json" python3 - <<'PY'
import json
import os
from pathlib import Path

root = Path.cwd()
version = (root / "VERSION").read_text().strip()
tmp_json = Path(os.environ["TMP_JSON"]).resolve()
data = json.loads(tmp_json.read_text())

assert data["meta"]["version"] == version
assert data["meta"]["schema_version"] == "1"
assert "summary" in data
assert "records" in data
print("json schema ok")
PY
