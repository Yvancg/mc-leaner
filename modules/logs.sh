#!/bin/bash
# shellcheck shell=bash
# mc-leaner: logs module (inspection-first)
# Purpose: identify large log files and log directories (user + system)
# Safety: dry-run by default; optional move-to-backup when --apply is used


# NOTE: Modules run with strict mode for deterministic failures and auditability.
set -euo pipefail

# ----------------------------
# Defensive Checks
# ----------------------------
# Purpose: Provide safe fallbacks when shared helpers are not loaded.
# Safety: Logging and temp-file helpers only; must not change inspection or cleanup behavior.
if ! type explain_log >/dev/null 2>&1; then
  explain_log() {
    # Purpose: Best-effort verbose logging when --explain is enabled.
    # Safety: Logging only.
    if [[ "${EXPLAIN:-false}" == "true" ]]; then
      log "$@"
    fi
  }
fi

if ! type tmpfile >/dev/null 2>&1; then
  tmpfile() {
    # Purpose: Create a temporary file path.
    # Safety: Returns a path only; caller owns content.
    mktemp -t mcleaner.XXXXXX 2>/dev/null || mktemp 2>/dev/null
  }
fi

if ! type tmpfile_cleanup >/dev/null 2>&1; then
  tmpfile_cleanup() {
    # Purpose: best-effort temp cleanup when run standalone.
    local f
    for f in "$@"; do
      [[ -n "$f" && -e "$f" ]] && rm -f "$f" 2>/dev/null || true
    done
  }
fi

# ----------------------------
# Helpers
# ----------------------------
_logs_mtime() {
  # Purpose: human-readable mtime for a path
  # Notes: BSD stat on macOS
  local p="$1"
  stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$p" 2>/dev/null || echo "unknown"
}

_logs_owner_label() {
  # Purpose: best-effort "owner" grouping label
  # Inputs: absolute path to a log file/dir
  local p="$1"

  case "$p" in
    "$HOME/Library/Logs"/*)
      # ~/Library/Logs/<owner>/...
      local rest
      rest="${p#"$HOME/Library/Logs/"}"
      echo "${rest%%/*}"
      ;;
    "/Library/Logs"/*)
      # /Library/Logs/<owner>/...
      local rest
      rest="${p#"/Library/Logs/"}"
      echo "${rest%%/*}"
      ;;
    "/var/log"/*)
      echo "system"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

_logs_is_user_level() {
  # Purpose: decide whether a path is user-level (safe by default)
  local p="$1"
  case "$p" in
    "$HOME/Library/Logs"/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_logs_rotations_summary() {
  # Purpose: in explain mode, summarize rotated siblings for a log file
  # Notes: best-effort; shows common rotation patterns next to the base file
  local p="$1"
  local dir
  local base

  dir="$(dirname "$p")"
  base="$(basename "$p")"

  # Skip if directory is unreadable
  [[ -d "$dir" ]] || return 0

  # Common rotations:
  #   file.log.1
  #   file.log.2
  #   file.log.0.gz
  #   file.log.1.gz
  #   file.log.gz
  # Also include *.old
  local matches=()
  local fp
  for fp in "$dir/$base".old "$dir/$base".gz "$dir/$base".[0-9]* "$dir/$base".[0-9]*.gz; do
    [[ -e "$fp" ]] || continue
    matches+=("$(basename "$fp" 2>/dev/null || printf '%s' '')")
  done
  [[ ${#matches[@]} -gt 0 ]] || return 0

  _logs_explain "  Rotated (same dir):"

  # Print each match with size
  local f
  for f in "${matches[@]}"; do
    [[ -n "$f" ]] || continue
    local fp
    fp="$dir/$f"
    local kb
    kb=$(du -sk "$fp" 2>/dev/null | awk '{print $1}' || echo "0")
    local mb
    mb=$((kb / 1024))
    _logs_explain "    - ${mb}MB | ${f}"
  done
}

_logs_confirm_move() {
  # Purpose: confirm move for an item
  # Behavior: use GUI prompt if available and not disabled, else terminal prompt
  # Safety: never assumes an answer in non-interactive contexts
  # Returns:
  #   0 = confirmed (yes)
  #   1 = declined (explicit no / anything else)
  #   2 = could not prompt (non-interactive / no tty)
  local p="$1"

  if [[ "${NO_GUI:-false}" == "false" ]] && command -v ask_yes_no >/dev/null 2>&1; then
    if ask_yes_no $'Move this log item to backup?\n\n'"${p}"; then
      return 0
    fi
    return 1
  fi

  if [[ "${NO_GUI:-false}" == "false" ]] && type ask_gui >/dev/null 2>&1; then
    if ask_gui "$p"; then
      return 0
    fi
    return 1
  fi

  # Terminal prompt fallback
  # IMPORTANT: stdin may not be a TTY even when invoked from a terminal (wrappers, redirects).
  # Prefer /dev/tty when available so prompts still work.
  local prompt_in=""
  if [[ -r /dev/tty ]]; then
    prompt_in="/dev/tty"
  elif [[ -t 0 ]]; then
    prompt_in="/dev/stdin"
  else
    # Cannot safely prompt (no controlling TTY)
    return 2
  fi

  # Write the prompt to the controlling terminal when possible
  if [[ -w /dev/tty ]]; then
    printf "Move to backup? %s [y/N] " "$p" > /dev/tty
  else
    printf "Move to backup? %s [y/N] " "$p"
  fi

  local ans=""
  if ! IFS= read -r ans < "$prompt_in"; then
    # No input received (EOF). Treat as non-response.
    return 2
  fi

  case "$ans" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_logs_move_to_backup() {
  # Purpose: move a path to backup safely (best-effort)
  # Notes: uses move_attempt from fs.sh; contract: see shared move/error contract
  local p="$1"
  local backup_dir="$2"

  # Defensive: require shared move helper
  if ! type move_attempt >/dev/null 2>&1; then
    log "Logs: SKIP (move helper missing): $p"
    return 1
  fi

  mkdir -p "$backup_dir"

  if ! move_attempt "$p" "$backup_dir"; then
    # IMPORTANT: do not log here; caller aggregates failures
    printf '%s\n' "${MOVE_LAST_MESSAGE:-failed}"
    return 1
  fi

  log "Moved: $p -> ${MOVE_LAST_DEST:-}"
  return 0
}

# ----------------------------
# Module Entry Point
# ----------------------------
run_logs_module() {
  # Contract:
  #   run_logs_module <apply> <backup_dir> <explain> <threshold_mb>
  local apply="$1"
  local backup_dir="$2"
  local explain="$3"
  local threshold_mb="$4"

  # Inputs
  log "Logs: apply=${apply} backup_dir=${backup_dir} explain=${explain} threshold_mb=${threshold_mb:-<none>}"

  # Stable exported summary fields (must be set even on early returns).
  LOGS_FLAGGED_COUNT="0"
  LOGS_TOTAL_MB="0"
  LOGS_MOVED_COUNT="0"
  LOGS_FAILURES_COUNT="0"
  LOGS_SCANNED_DIRS="0"
  LOGS_THRESHOLD_MB="${threshold_mb:-50}"
  LOGS_FLAGGED_IDS_LIST=""

  _logs_explain() {
    [[ "${explain}" == "true" ]] || return 0
    # Prefer shared explain_log when present; fall back to normal log.
    if type explain_log >/dev/null 2>&1; then
      explain_log "$@"
    else
      log "$@"
    fi
  }

  # Timing (best-effort wall clock duration for this module).
  local _logs_t0="" _logs_t1=""
  _logs_t0="$(/bin/date +%s 2>/dev/null || echo '')"
  LOGS_DUR_S=0

  local -a _logs_tmpfiles
  _logs_tmpfiles=()

  _logs_finish_timing() {
    _logs_t1="$(/bin/date +%s 2>/dev/null || printf '')"

    # Guard arithmetic in strict mode: only compute if both are integers.
    if [[ "${_logs_t0:-}" =~ ^[0-9]+$ && "${_logs_t1:-}" =~ ^[0-9]+$ ]]; then
      LOGS_DUR_S=$((_logs_t1 - _logs_t0))
    fi
  }

  _logs_tmp_cleanup() { tmpfile_cleanup "${_logs_tmpfiles[@]:-}"; }

  _logs_on_return() {
    _logs_finish_timing
    _logs_tmp_cleanup
  }
  trap _logs_on_return RETURN

  # End-of-run contract arrays
  local -a flagged_items=()
  local -a flagged_ids=()
  local -a move_failures=()
  local moved_count=0

  # Validate threshold
  if [[ -z "$threshold_mb" ]]; then
    threshold_mb="50"
  fi

  # Minimum sanity
  if ! echo "$threshold_mb" | grep -Eq '^[0-9]+$'; then
    log "Logs: invalid threshold MB: $threshold_mb (expected integer)"
    return 1
  fi

  log "Logs: scanning log locations (min ${threshold_mb}MB)..."

  # Locations
  local locations
  locations=(
    "$HOME/Library/Logs"
    "/Library/Logs"
    "/var/log"
  )

  local scanned_dirs=0

  local tmp
  tmp="$(tmpfile)"
  : > "$tmp"
  _logs_tmpfiles+=("${tmp}")

  # Collect candidates: both files and directories.
  # We keep the scan conservative and bounded:
  # - For directories: compute du size of the directory itself
  # - For files: du size of the file
  local loc
  for loc in "${locations[@]}"; do
    [[ -e "$loc" ]] || continue

    _logs_explain "Logs (explain): sizing $loc"

    # Enumerate immediate children only to keep scan fast.
    # Users can drill down with explain mode.
    local child
    for child in "$loc"/*; do
      [[ -e "$child" ]] || continue

      scanned_dirs=$((scanned_dirs + 1))

      # Skip known protected/security patterns (best-effort)
      case "$child" in
        *bitdefender*|*malwarebytes*|*crowdstrike*|*sentinel*|*sophos*|*carbonblack*|*defender*|*endpoint*)
          _logs_explain "Logs: SKIP (protected): $child"
          continue
          ;;
      esac

      # Size in KB
      local kb
      kb=$(du -sk "$child" 2>/dev/null | awk '{print $1}' || echo "0")
      local mb
      mb=$((kb / 1024))

      if [[ "$mb" -lt "$threshold_mb" ]]; then
        continue
      fi

      local mod
      mod="$(_logs_mtime "$child")"

      local owner
      owner="$(_logs_owner_label "$child")"

      # owner|mb|mod|path
      printf "%s|%s|%s|%s\n" "$owner" "$mb" "$mod" "$child" >> "$tmp"
    done
  done

  local found
  found=$(wc -l < "$tmp" 2>/dev/null | tr -d ' ' || echo "0")

  LOGS_SCANNED_DIRS="${scanned_dirs}"

  if [[ "$found" -eq 0 ]]; then
    log "Logs: no large log items found (by threshold)."
    if type summary_add >/dev/null 2>&1; then
      summary_add "logs" "flagged=0 total_mb=0 moved=0 failures=0 scanned=${scanned_dirs} threshold_mb=${threshold_mb}"
    fi
    return 0
  fi

  # Sort by owner then size desc
  local sorted
  sorted="$(tmpfile)"
  _logs_tmpfiles+=("${sorted}")
  sort -t '|' -k1,1 -k2,2nr "$tmp" > "$sorted" 2>/dev/null || cp "$tmp" "$sorted"

  local total_mb=0
  local current_owner=""

  while IFS='|' read -r owner mb mod path; do
    [[ -n "${path:-}" ]] || continue

    total_mb=$((total_mb + mb))

    if [[ "$owner" != "$current_owner" ]]; then
      current_owner="$owner"
      log "LOG GROUP: $owner"
    fi

    # Default output: one line per item
    log "LOG? ${mb}MB | modified: ${mod} | path: ${path}"
    # End-of-run summary: aggregate flagged items
    flagged_items+=("${mb}MB | modified: ${mod} | owner: ${owner} | ${path}")
    flagged_ids+=("${path}")

    # Explain output: rotations + reason
    if [[ "${explain}" == "true" ]]; then
      _logs_explain "  reason: >= ${threshold_mb}MB"

      # For user-level Logs/<owner>, also show top subfolders for directories
      if [[ -d "$path" ]]; then
        _logs_explain "  Subfolders (top 3 by size):"

        # NOTE: with `set -euo pipefail`, a pipeline fails the whole script if any stage
        # returns non-zero. When a directory has no children, the glob may not match and
        # `du` can fail. Guard by checking for at least one child first.
        local -a _children
        _children=("$path"/*)
        if [[ ${#_children[@]} -gt 0 && -e "${_children[0]}" ]]; then
          # Best-effort; never abort the module on explain-only details.
          du -sk "${_children[@]}" 2>/dev/null \
            | sort -nr \
            | head -n 3 \
            | while IFS=$'\t' read -r skb sub; do
                [[ -n "${skb:-}" && -n "${sub:-}" ]] || continue
                local smb=$((skb / 1024))
                _logs_explain "    - ${smb}MB | ${sub}"
              done \
            || true
        else
          _logs_explain "    (no subfolders)"
        fi
      else
        _logs_rotations_summary "$path"
      fi
    fi

    # Optional cleanup
    if [[ "$apply" == "true" ]]; then
      if _logs_is_user_level "$path"; then
        if _logs_confirm_move "$path"; then
          # Use move contract: capture output and status
          local move_out=""
          if move_out="$(_logs_move_to_backup "$path" "$backup_dir")"; then
            moved_count=$((moved_count + 1))
          else
            move_failures+=("${path} | ${move_out}")
            log "Logs: move failed: ${path} | ${move_out}"
          fi
        else
          local rc=$?
          if [[ "$rc" -eq 2 ]]; then
            _logs_explain "Logs: SKIP (non-interactive; cannot prompt): $path"
          else
            _logs_explain "Logs: SKIP (user declined): $path"
          fi
        fi
      else
        # System logs require explicit confirmation
        log "Logs: system path detected (confirm carefully): $path"
        if _logs_confirm_move "$path"; then
          local move_out=""
          if move_out="$(_logs_move_to_backup "$path" "$backup_dir")"; then
            moved_count=$((moved_count + 1))
          else
            move_failures+=("${path} | ${move_out}")
            log "Logs: move failed: ${path} | ${move_out}"
          fi
        else
          local rc=$?
          if [[ "$rc" -eq 2 ]]; then
            _logs_explain "Logs: SKIP (non-interactive; cannot prompt): $path"
          else
            _logs_explain "Logs: SKIP (user declined): $path"
          fi
        fi
      fi
    fi

  done < "$sorted"

  # End-of-run summary contract
  log "Logs: flagged ${#flagged_items[@]} item(s)."
  log "Logs: flagged items:"
  if [[ "${#flagged_items[@]}" -gt 0 ]]; then
    for item in "${flagged_items[@]}"; do
      log "  - ${item}"
    done
  fi
  if [[ "${#move_failures[@]}" -gt 0 ]]; then
    log "Logs: move failures:"
    for failure in "${move_failures[@]}"; do
      log "  - ${failure}"
    done
  fi

  log "Logs: total large log items (by threshold): ${total_mb}MB"

  LOGS_FLAGGED_COUNT="${#flagged_ids[@]}"
  LOGS_TOTAL_MB="${total_mb}"
  LOGS_MOVED_COUNT="${moved_count}"
  LOGS_FAILURES_COUNT="${#move_failures[@]}"
  LOGS_SCANNED_DIRS="${scanned_dirs}"
  LOGS_THRESHOLD_MB="${threshold_mb}"

  LOGS_FLAGGED_IDS_LIST="$({ printf '%s\n' "${flagged_ids[@]:-}"; } 2>/dev/null || true)"
  LOGS_DUR_S="${LOGS_DUR_S:-0}"

  # ----------------------------
  # Global summary contribution
  # ----------------------------
  if type summary_add >/dev/null 2>&1; then
    summary_add "logs" "flagged=${#flagged_items[@]} total_mb=${total_mb} moved=${moved_count} failures=${#move_failures[@]} scanned=${scanned_dirs} threshold_mb=${threshold_mb}"
  fi

  if [[ "$apply" != "true" ]]; then
    log "Logs: run with --apply to relocate selected log items (user-confirmed, reversible)"
  fi
}

# End of module
