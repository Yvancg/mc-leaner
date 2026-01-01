#!/bin/bash
set -euo pipefail

ts() { date +"%Y-%m-%d %H:%M:%S"; }
log() { printf "[%s] %s\n" "$(ts)" "$*"; }

is_cmd() { command -v "$1" >/dev/null 2>&1; }

tmpfile() {
  # bash 3.2 safe temp file
  mktemp "/tmp/mc-leaner.XXXXXX"
}
