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
  [[ -e "$src" || -L "$src" ]] || return 1
  ensure_dir "$dst_dir" || return 1

  local base
  base="$(basename "$src")"

  # Allocate a private container atomically. Keeping the original basename
  # inside it avoids collisions without a check-then-move race.
  local reservation
  reservation="$(/usr/bin/mktemp -d "${dst_dir}/.mcleaner-item.XXXXXX" 2>/dev/null)" || return 1
  local dst="${reservation}/${base}"

  local parent
  parent="$(dirname "$src")"

  # SAFETY: try non-sudo first; escalate only for permission-style failures.
  local err rc
  err=""
  if [[ -w "$parent" ]]; then
    if err="$(LC_ALL=C /bin/mv "$src" "$dst" 2>&1)"; then
      rc=0
    else
      rc=$?
    fi
  else
    if [[ "${ALLOW_SUDO:-false}" != "true" ]]; then
      err="sudo disabled (use --allow-sudo)"
      rc=1
    else
      if err="$(LC_ALL=C sudo /bin/mv "$src" "$dst" 2>&1)"; then
        rc=0
      else
        rc=$?
      fi
    fi
  fi

  if [[ $rc -ne 0 ]]; then
    # SAFETY: retry with sudo only when the first attempt was non-sudo and the error is permission-like.
    if [[ -w "$parent" ]] && { [[ "$err" == *"Operation not permitted"* ]] || [[ "$err" == *"Permission denied"* ]]; }; then
      if [[ "${ALLOW_SUDO:-false}" != "true" ]]; then
        echo "sudo disabled (use --allow-sudo)" >&2
        rmdir "$reservation" 2>/dev/null || true
        return $rc
      fi
      if ! LC_ALL=C sudo /bin/mv "$src" "$dst"; then
        rmdir "$reservation" 2>/dev/null || true
        return "$rc"
      fi
    else
      echo "$err" >&2
      rmdir "$reservation" 2>/dev/null || true
      return $rc
    fi
  fi

  echo "$dst"
}

# ----------------------------
# Backup manifest
# ----------------------------

backup_manifest_path() {
  # Purpose: return manifest path for a backup directory
  local backup_dir="$1"
  [[ -n "$backup_dir" ]] || return 1
  printf '%s/.mcleaner_manifest.tsv' "$backup_dir"
}

backup_manifest_checksum_path() {
  # Purpose: return checksum path for a backup directory
  local backup_dir="$1"
  [[ -n "$backup_dir" ]] || return 1
  printf '%s/.mcleaner_manifest.sha256' "$backup_dir"
}

backup_manifest_lock_acquire() {
  local backup_dir="$1"
  local lock_dir="${backup_dir}/.mcleaner-manifest.lock"
  local attempts=0
  local current_pid
  current_pid="$(/bin/sh -c 'printf "%s" "$PPID"')"
  [[ "$current_pid" =~ ^[0-9]+$ ]] || return 1
  ensure_dir "$backup_dir" || return 1

  while [[ "$attempts" -lt 200 ]]; do
    if mkdir "$lock_dir" 2>/dev/null; then
      printf '%s\n' "$current_pid" > "${lock_dir}/pid" 2>/dev/null || {
        rmdir "$lock_dir" 2>/dev/null || true
        return 1
      }
      return 0
    fi

    local owner_pid=""
    if [[ -r "${lock_dir}/pid" ]]; then
      IFS= read -r owner_pid < "${lock_dir}/pid" || owner_pid=""
    fi
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
      rm -f "${lock_dir}/pid" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null || true
    fi

    attempts=$((attempts + 1))
    /bin/sleep 0.05
  done

  return 1
}

backup_manifest_lock_release() {
  local backup_dir="$1"
  local lock_dir="${backup_dir}/.mcleaner-manifest.lock"
  rm -f "${lock_dir}/pid" 2>/dev/null || true
  rmdir "$lock_dir" 2>/dev/null || true
}

backup_manifest_ensure_header() {
  # Purpose: ensure a header is present for v2 manifests
  local backup_dir="$1"
  local manifest
  manifest="$(backup_manifest_path "$backup_dir")" || return 1

  [[ ! -L "$manifest" ]] || return 1

  if [[ -s "$manifest" ]]; then
    return 0
  fi

  local ts
  ts="$(/bin/date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")"
  {
    printf '%s\n' "# mcleaner_manifest_v=2"
    printf '%s\n' "# created_at=${ts}"
    printf '%s\n' "# version=${MCLEANER_VERSION:-unknown}"
    printf '%s\n' "# encoding=base64"
    printf '%s\n' "# fields=epoch\tpath_src_b64\tpath_dest_b64"
  } >> "$manifest" 2>/dev/null || return 1

  return 0
}

backup_manifest_format_detect() {
  # Purpose: detect manifest format (v2 base64 or legacy)
  # Output: echoes "v2" or "legacy"
  local backup_dir="$1"
  local manifest
  manifest="$(backup_manifest_path "$backup_dir")" || { printf '%s' "legacy"; return 0; }
  [[ -f "$manifest" ]] || { printf '%s' "legacy"; return 0; }

  local line ts src_field dest_field decoded
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    if [[ "$line" == \#* ]]; then
      if [[ "$line" == "# mcleaner_manifest_v=2"* ]]; then
        printf '%s' "v2"
        return 0
      fi
      continue
    fi
    IFS=$'\t' read -r ts src_field dest_field <<< "$line"
    [[ -n "$src_field" && -n "$dest_field" ]] || continue
    if [[ "$src_field" =~ ^[A-Za-z0-9+/=]+$ && "$dest_field" =~ ^[A-Za-z0-9+/=]+$ ]]; then
      decoded="$(printf '%s' "$src_field" | /usr/bin/base64 -D 2>/dev/null || true)"
      if [[ -n "$decoded" && "$decoded" == /* ]]; then
        decoded="$(printf '%s' "$dest_field" | /usr/bin/base64 -D 2>/dev/null || true)"
        if [[ -n "$decoded" && "$decoded" == /* ]]; then
          printf '%s' "v2"
          return 0
        fi
      fi
    fi
    printf '%s' "legacy"
    return 0
  done < "$manifest"

  printf '%s' "legacy"
  return 0
}

backup_manifest_checksum_update() {
  # Purpose: update checksum file for the manifest (best-effort)
  local backup_dir="$1"
  local manifest
  manifest="$(backup_manifest_path "$backup_dir")" || return 1
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 1

  local checksum
  checksum="$(/usr/bin/shasum -a 256 "$manifest" 2>/dev/null | awk '{print $1}')"
  [[ -n "$checksum" ]] || return 1

  local checksum_file
  checksum_file="$(backup_manifest_checksum_path "$backup_dir")" || return 1
  [[ ! -L "$checksum_file" ]] || return 1
  printf '%s\n' "$checksum" > "$checksum_file" 2>/dev/null || return 1
  return 0
}

backup_manifest_checksum_verify() {
  # Purpose: verify checksum for a backup manifest
  # Returns:
  #  0 = ok
  #  1 = checksum missing
  #  2 = checksum mismatch
  #  3 = error
  local backup_dir="$1"
  local manifest checksum_file expected_checksum actual_checksum

  manifest="$(backup_manifest_path "$backup_dir")" || return 3
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 3

  checksum_file="$(backup_manifest_checksum_path "$backup_dir")" || return 3
  [[ -f "$checksum_file" && ! -L "$checksum_file" ]] || return 1

  expected_checksum="$(head -n 1 "$checksum_file" 2>/dev/null | tr -d '[:space:]')"
  actual_checksum="$(/usr/bin/shasum -a 256 "$manifest" 2>/dev/null | awk '{print $1}')"
  [[ -n "$expected_checksum" && -n "$actual_checksum" ]] || return 3

  if [[ "$expected_checksum" != "$actual_checksum" ]]; then
    return 2
  fi

  return 0
}

_backup_manifest_append_locked() {
  # Purpose: atomically record a move in the backup manifest.
  local src="$1"
  local dest="$2"
  local backup_dir="$3"

  [[ -n "$backup_dir" && -n "$src" && -n "$dest" ]] || return 1
  ensure_dir "$backup_dir" || return 1

  local manifest checksum_file
  manifest="$(backup_manifest_path "$backup_dir")" || return 1
  checksum_file="$(backup_manifest_checksum_path "$backup_dir")" || return 1
  [[ ! -L "$manifest" && ! -L "$checksum_file" ]] || return 1

  local tmp_manifest tmp_checksum
  tmp_manifest="$(/usr/bin/mktemp "${backup_dir}/.mcleaner-manifest.XXXXXX" 2>/dev/null)" || return 1
  tmp_checksum="$(/usr/bin/mktemp "${backup_dir}/.mcleaner-checksum.XXXXXX" 2>/dev/null)" || {
    rm -f "$tmp_manifest" 2>/dev/null || true
    return 1
  }

  if [[ -s "$manifest" ]]; then
    cp "$manifest" "$tmp_manifest" 2>/dev/null || {
      rm -f "$tmp_manifest" "$tmp_checksum" 2>/dev/null || true
      return 1
    }
  else
    local created_at
    created_at="$(/bin/date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '')"
    {
      printf '%s\n' "# mcleaner_manifest_v=2"
      printf '%s\n' "# created_at=${created_at}"
      printf '%s\n' "# version=${MCLEANER_VERSION:-unknown}"
      printf '%s\n' "# encoding=base64"
      printf '%s\n' "# fields=epoch\tpath_src_b64\tpath_dest_b64"
    } > "$tmp_manifest" 2>/dev/null || {
      rm -f "$tmp_manifest" "$tmp_checksum" 2>/dev/null || true
      return 1
    }
  fi

  local ts
  ts="$(/bin/date +%s 2>/dev/null || echo "")"

  local src_b64 dest_b64
  src_b64="$(printf '%s' "$src" | /usr/bin/base64 2>/dev/null | tr -d '\n')"
  dest_b64="$(printf '%s' "$dest" | /usr/bin/base64 2>/dev/null | tr -d '\n')"

  [[ -n "$src_b64" && -n "$dest_b64" ]] || {
    rm -f "$tmp_manifest" "$tmp_checksum" 2>/dev/null || true
    return 1
  }

  # Format: epoch<TAB>src_b64<TAB>dest_b64
  printf '%s\t%s\t%s\n' "$ts" "$src_b64" "$dest_b64" >> "$tmp_manifest" 2>/dev/null || {
    rm -f "$tmp_manifest" "$tmp_checksum" 2>/dev/null || true
    return 1
  }

  local checksum
  checksum="$(/usr/bin/shasum -a 256 "$tmp_manifest" 2>/dev/null | awk '{print $1}')"
  [[ -n "$checksum" ]] || {
    rm -f "$tmp_manifest" "$tmp_checksum" 2>/dev/null || true
    return 1
  }
  printf '%s\n' "$checksum" > "$tmp_checksum" 2>/dev/null || {
    rm -f "$tmp_manifest" "$tmp_checksum" 2>/dev/null || true
    return 1
  }

  # Install the checksum first. If the manifest replacement fails, restore a
  # checksum for the previous manifest so an existing backup remains usable.
  if ! /bin/mv "$tmp_checksum" "$checksum_file" 2>/dev/null; then
    rm -f "$tmp_manifest" "$tmp_checksum" 2>/dev/null || true
    return 1
  fi
  if ! /bin/mv "$tmp_manifest" "$manifest" 2>/dev/null; then
    rm -f "$tmp_manifest" 2>/dev/null || true
    backup_manifest_checksum_update "$backup_dir" || true
    return 1
  fi

  return 0
}

backup_manifest_append() {
  local src="$1"
  local dest="$2"
  local backup_dir="$3"
  local rc

  backup_manifest_lock_acquire "$backup_dir" || return 1
  if _backup_manifest_append_locked "$src" "$dest" "$backup_dir"; then
    rc=0
  else
    rc=$?
  fi
  backup_manifest_lock_release "$backup_dir"
  return "$rc"
}

backup_manifest_preflight() {
  local backup_dir="$1"
  [[ -n "$backup_dir" ]] || return 1
  ensure_dir "$backup_dir" || return 1

  local manifest checksum_file probe
  manifest="$(backup_manifest_path "$backup_dir")" || return 1
  checksum_file="$(backup_manifest_checksum_path "$backup_dir")" || return 1
  [[ ! -L "$manifest" && ! -L "$checksum_file" ]] || return 1

  probe="$(/usr/bin/mktemp "${backup_dir}/.mcleaner-preflight.XXXXXX" 2>/dev/null)" || return 1
  rm -f "$probe" 2>/dev/null || return 1
  return 0
}

# ----------------------------
# Move attempt contract
# ----------------------------

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

  if [[ ! -e "$src" && ! -L "$src" ]]; then
    MOVE_LAST_STATUS="skipped"
    MOVE_LAST_CODE="not_found"
    MOVE_LAST_MESSAGE="source does not exist"
    return 1
  fi

  if declare -F is_protected_path >/dev/null 2>&1 && is_protected_path "$src"; then
    MOVE_LAST_STATUS="skipped"
    MOVE_LAST_CODE="protected"
    MOVE_LAST_MESSAGE="protected security or endpoint software path"
    return 1
  fi

  if declare -F is_report_only_system_path >/dev/null 2>&1 && is_report_only_system_path "$src"; then
    MOVE_LAST_STATUS="skipped"
    MOVE_LAST_CODE="system_path"
    MOVE_LAST_MESSAGE="system launchd and log paths are report-only"
    return 1
  fi

  if ! backup_manifest_preflight "$backup_dir"; then
    MOVE_LAST_STATUS="failed"
    MOVE_LAST_CODE="manifest"
    MOVE_LAST_MESSAGE="backup manifest is not writable"
    return 1
  fi

  local out rc
  if out="$(safe_move "$src" "$backup_dir" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi

  if [[ $rc -ne 0 ]]; then
    classify_move_error "$out"
    MOVE_LAST_STATUS="failed"
    MOVE_LAST_MESSAGE="$out"
    return 1
  fi

  if ! backup_manifest_append "$src" "$out" "$backup_dir"; then
    local rollback_message=""
    if rollback_message="$(safe_restore "$out" "$src" 2>&1)"; then
      MOVE_LAST_STATUS="failed"
      MOVE_LAST_CODE="manifest"
      MOVE_LAST_MESSAGE="manifest update failed; move rolled back"
    else
      MOVE_LAST_STATUS="failed"
      MOVE_LAST_CODE="manifest"
      MOVE_LAST_DEST="$out"
      MOVE_LAST_MESSAGE="manifest update failed; rollback failed: ${rollback_message}; item remains at ${out}"
    fi
    return 1
  fi

  MOVE_LAST_STATUS="moved"
  MOVE_LAST_DEST="$out"
  MOVE_LAST_MESSAGE="moved"
  return 0
}

# ----------------------------
# Restore
# ----------------------------

safe_restore() {
  # Purpose: move a path from backup to its original location
  # Safety: never overwrites existing paths; uses sudo only when required.
  # Output: echoes destination path on success.
  local backup_path="$1"
  local restore_path="$2"
  local source_identity source_device

  [[ -e "$backup_path" || -L "$backup_path" ]] || return 1
  [[ -n "$restore_path" ]] || return 1

  if [[ -e "$restore_path" || -L "$restore_path" ]]; then
    echo "restore target exists" >&2
    return 1
  fi

  source_identity="$(/usr/bin/stat -f '%d:%i' "$backup_path" 2>/dev/null)"
  source_device="${source_identity%%:*}"
  [[ -n "$source_identity" ]] || return 1

  local parent
  parent="$(dirname "$restore_path")"

  if [[ ! -d "$parent" ]]; then
    if ! mkdir -p "$parent" 2>/dev/null; then
      if [[ "${ALLOW_SUDO:-false}" != "true" ]]; then
        echo "sudo disabled (use --allow-sudo)" >&2
        return 1
      fi
      sudo mkdir -p "$parent" 2>/dev/null || true
    fi
  fi

  local err rc
  err=""
  if [[ -w "$parent" ]]; then
    if err="$(LC_ALL=C /bin/mv -n "$backup_path" "$restore_path" 2>&1)"; then
      rc=0
    else
      rc=$?
    fi
  else
    if [[ "${ALLOW_SUDO:-false}" != "true" ]]; then
      err="sudo disabled (use --allow-sudo)"
      rc=1
    else
      if err="$(LC_ALL=C sudo /bin/mv -n "$backup_path" "$restore_path" 2>&1)"; then
        rc=0
      else
        rc=$?
      fi
    fi
  fi

  if [[ $rc -ne 0 ]]; then
    if [[ -w "$parent" ]] && { [[ "$err" == *"Operation not permitted"* ]] || [[ "$err" == *"Permission denied"* ]]; }; then
      if [[ "${ALLOW_SUDO:-false}" != "true" ]]; then
        echo "sudo disabled (use --allow-sudo)" >&2
        return $rc
      fi
      LC_ALL=C sudo /bin/mv -n "$backup_path" "$restore_path" || return "$rc"
    else
      echo "$err" >&2
      return $rc
    fi
  fi

  # BSD mv -n exits successfully when it declines an overwrite. Verify that
  # the source actually moved so a race cannot be reported as a restore.
  if [[ -e "$backup_path" || -L "$backup_path" ]]; then
    echo "restore target exists" >&2
    return 1
  fi

  local restored_identity parent_device
  restored_identity="$(/usr/bin/stat -f '%d:%i' "$restore_path" 2>/dev/null || true)"
  parent_device="$(/usr/bin/stat -f '%d' "$parent" 2>/dev/null || true)"
  if [[ -n "$parent_device" && "$source_device" == "$parent_device" && "$restored_identity" != "$source_identity" ]]; then
    local nested_path nested_identity
    nested_path="${restore_path}/$(basename "$backup_path")"
    nested_identity="$(/usr/bin/stat -f '%d:%i' "$nested_path" 2>/dev/null || true)"
    if [[ "$nested_identity" == "$source_identity" ]]; then
      /bin/mv -n "$nested_path" "$backup_path" 2>/dev/null || true
    fi
    echo "restore target changed during move" >&2
    return 1
  fi

  local backup_container
  backup_container="$(dirname "$backup_path")"
  case "$(basename "$backup_container")" in
    .mcleaner-item.*) rmdir "$backup_container" 2>/dev/null || true ;;
  esac

  echo "$restore_path"
}

# ----------------------------
# Symlink resolution
# ----------------------------

# Resolve parent directories physically while preserving the final directory
# entry. This is used when the entry itself may be a symlink that must be moved
# or restored rather than followed.
fs_physical_entry_path() {
  local path="$1"
  local parent parent_real base
  [[ -n "$path" ]] || return 1
  parent="$(dirname "$path")"
  base="$(basename "$path")"
  parent_real="$(cd "$parent" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s' "${parent_real%/}" "$base"
}

# Purpose: Resolve a symlink chain to its final physical target.
# Contract:
#   fs_resolve_symlink_target_physical <path>
# Output:
#   Prints resolved absolute path, or empty string on failure.
# Safety:
#   Read-only. Best-effort. Fail-closed.
fs_resolve_symlink_target_physical() {
  local p="$1"
  local max_depth=40
  local i=0

  [[ -n "$p" ]] || return 0
  [[ -e "$p" || -L "$p" ]] || return 0

  while [[ -L "$p" && $i -lt $max_depth ]]; do
    local target
    target="$(readlink "$p" 2>/dev/null)" || return 0
    if [[ "$target" = /* ]]; then
      p="$target"
    else
      p="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/$target" || return 0
    fi
    i=$((i + 1))
  done

  if [[ -e "$p" ]]; then
    (cd "$(dirname "$p")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$p")") || return 0
  fi

  return 0
}

# ----------------------------
# Script shim inspection
# ----------------------------

# Purpose: Detect script shims that reference an app bundle.
# Contract:
#   fs_script_shim_app_bundle_ref <file> [max_bytes] [prefix_bytes]
# Output:
#   Prints resolved .app path if detected, otherwise empty.
# Safety:
#   Read-only. Best-effort. Fail-closed.
fs_script_shim_app_bundle_ref() {
  local f="$1"
  local max_bytes="${2:-65536}"
  local prefix_bytes="${3:-4096}"

  [[ -f "$f" ]] || return 0

  local size
  size="$(wc -c <"$f" 2>/dev/null)" || return 0
  [[ "$size" -le "$max_bytes" ]] || return 0

  # Shebang-only scripts
  local first
  first="$(head -n 1 "$f" 2>/dev/null)" || return 0
  [[ "$first" == '#!'* ]] || return 0

  local chunk
  chunk="$(head -c "$prefix_bytes" "$f" 2>/dev/null)" || return 0

  local app
  app="$(printf '%s' "$chunk" \
    | LC_ALL=C grep -Eo '/(System/Applications|Applications|Users/[^/]+/Applications)/[^[:space:]]+\.app' 2>/dev/null \
    | head -n 1)" || true

  [[ -n "$app" ]] || return 0

  if [[ "$app" == *.app/* ]]; then
    app="${app%%.app/*}.app"
  fi

  printf '%s\n' "$app"
}

# End of library
