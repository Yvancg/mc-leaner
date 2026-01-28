#!/bin/bash
# mc-leaner: filesystem safety helpers
# Purpose: Provide small, auditable filesystem primitives used by modules (create backup dirs, move files safely)
# Safety: Never deletes; uses `sudo` only when required to relocate protected files


# NOTE: This library avoids setting shell-global strict mode.
# The entrypoint (mc-leaner.sh) is responsible for `set -euo pipefail`.

# ----------------------------
# Directory Helpers
# ----------------------------

# Purpose: Ensure a directory exists.
# Safety: Uses mkdir -p; no deletions or permission escalation.
ensure_dir() {
  mkdir -p "$1"
}

# ----------------------------
# Safe Relocation
# ----------------------------

# Purpose: Move a single file/dir into a backup directory, preserving its name
# Safety: Never deletes. Uses `sudo` only when required.
# Output: Echoes destination path on success.
safe_move() {
  local src="$1"
  local dst_dir="$2"

  # No-op if the source does not exist (modules may race with system changes)
  [[ -e "$src" ]] || return 0
  ensure_dir "$dst_dir"

  local base
  base="$(basename "$src")"

  local dst="$dst_dir/$base"
  if [[ -e "$dst" ]]; then
    dst="$dst_dir/${base}_$(date +%Y%m%d_%H%M%S)"
  fi

  local parent
  parent="$(dirname "$src")"

  # SAFETY: try non-sudo first; escalate only for permission-style failures.
  local err rc
  err=""
  set +e
  if [[ -w "$parent" ]]; then
    err="$(mv "$src" "$dst" 2>&1)"
    rc=$?
  else
    err="$(sudo mv "$src" "$dst" 2>&1)"
    rc=$?
  fi
  set -e

  if [[ $rc -ne 0 ]]; then
    # SAFETY: retry with sudo only when the first attempt was non-sudo and the error is permission-like.
    if [[ -w "$parent" ]] && { [[ "$err" == *"Operation not permitted"* ]] || [[ "$err" == *"Permission denied"* ]]; }; then
      sudo mv "$src" "$dst"
    else
      echo "$err" >&2
      return $rc
    fi
  fi

  echo "$dst"
}

# ----------------------------
# Move attempt contract
# ----------------------------

# Contract fields for the last move attempt. Modules can read these.
MOVE_LAST_STATUS=""   # moved|failed|skipped
MOVE_LAST_CODE=""     # permission|busy|not_found|exists|unknown
MOVE_LAST_MESSAGE=""  # human-readable error or note
MOVE_LAST_DEST=""     # destination path when moved

#
# Contract fields for the last move attempt. Modules can read these.
MOVE_LAST_STATUS=""   # moved|failed|skipped
MOVE_LAST_CODE=""     # permission|busy|not_found|exists|unknown
MOVE_LAST_MESSAGE=""  # human-readable error or note
MOVE_LAST_DEST=""     # destination path when moved

# Purpose: Classify common mv errors into stable, user-facing codes.
classify_move_error() {
  local msg="$1"
  MOVE_LAST_CODE="unknown"

  if [[ "$msg" == *"Operation not permitted"* ]] || [[ "$msg" == *"Permission denied"* ]]; then
    MOVE_LAST_CODE="permission"
  elif [[ "$msg" == *"Resource busy"* ]] || [[ "$msg" == *"Device busy"* ]]; then
    MOVE_LAST_CODE="busy"
  elif [[ "$msg" == *"No such file"* ]] || [[ "$msg" == *"cannot stat"* ]]; then
    MOVE_LAST_CODE="not_found"
  elif [[ "$msg" == *"File exists"* ]]; then
    MOVE_LAST_CODE="exists"
  fi
}

# Purpose: Attempt a move and populate MOVE_LAST_* fields.
# Safety: Delegates actual move to safe_move(); does not delete.
move_attempt() {
  local src="$1"
  local backup_dir="$2"

  MOVE_LAST_STATUS=""
  MOVE_LAST_CODE=""
  MOVE_LAST_MESSAGE=""
  MOVE_LAST_DEST=""

  if [[ ! -e "$src" ]]; then
    MOVE_LAST_STATUS="skipped"
    MOVE_LAST_CODE="not_found"
    MOVE_LAST_MESSAGE="source does not exist"
    return 1
  fi

  local out rc
  set +e
  out="$(safe_move "$src" "$backup_dir" 2>&1)"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    classify_move_error "$out"
    MOVE_LAST_STATUS="failed"
    MOVE_LAST_MESSAGE="$out"
    return 1
  fi

  MOVE_LAST_STATUS="moved"
  MOVE_LAST_DEST="$out"
  MOVE_LAST_MESSAGE="moved"
  return 0
}

# End of library
