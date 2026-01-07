#!/bin/bash
# mc-leaner: leftovers module (inspection-first)
#
# Purpose
# - Identify user-level application leftovers (support files) for apps that no longer appear installed.
# - Inspection-first: report findings; optional relocation only when --apply is used.
#
# Scope (user-level only)
# - ~/Library/Application Support
# - ~/Library/Containers
# - ~/Library/Group Containers
# - ~/Library/Saved Application State
# - ~/Library/Preferences  (report-only in v1.4.0; no moves)
#
# Safety rules
# - Never touch system-level paths.
# - Never delete; relocation only to backup dir.
# - Prefer false negatives over false positives.
#
# Inputs
# - apply: "true" or "false"
# - backup_dir: destination for relocation when apply=true (reversible)
# - explain: "true" or "false" (verbose reasoning)
# - inventory_file: inventory.tsv produced by modules/inventory.sh (contains installed apps + brew)
#
# Output
# - Groups by inferred owner (bundle id or app name)
# - Reports size and last modified time (best-effort)
#
# Notes
# - Mapping of folder names to apps is heuristic-based. We prioritize safety and clarity.
# - In v1.4.0 we mainly target bundle-id named folders (e.g. com.vendor.App).
# - Later versions may expand mapping using LaunchServices metadata or Spotlight.


set -euo pipefail


# Global counter: number of LEFTOVER? findings emitted in this run.
LEFTOVERS_FLAGGED_COUNT=0

# Summary list of flagged items for end-of-run legibility.
# Format: one string per item (pre-formatted for display).
LEFTOVERS_FLAGGED_ITEMS=()


# Summary list of move failures for end-of-run legibility (apply-mode only).
# Format: one string per item (pre-formatted for display).
LEFTOVERS_MOVE_FAILURES=()

# Contribute to the global end-of-run summary (if available).
# Contract: modules should add a short, actionable summary of what was flagged and what failed.
_leftovers_summary_emit() {
  # summary_add is defined in lib/utils.sh and used by mc-leaner.sh to print a global summary.
  if ! command -v summary_add >/dev/null 2>&1; then
    return 0
  fi

  if [[ "${LEFTOVERS_FLAGGED_COUNT:-0}" -eq 0 ]]; then
    summary_add "Leftovers" "No items flagged"
    return 0
  fi

  summary_add "Leftovers" "Flagged: ${LEFTOVERS_FLAGGED_COUNT} item(s)"

  # If we had move failures in apply-mode, surface the count.
  if [[ "${#LEFTOVERS_MOVE_FAILURES[@]}" -gt 0 ]]; then
    summary_add "Leftovers" "Move failures: ${#LEFTOVERS_MOVE_FAILURES[@]} (see log for details)"
  fi
}

# Treat Apple/system-owned containers as protected. Users should not relocate these.
_leftovers_is_protected_owner() {
  local owner="$1"
  case "$owner" in
    com.apple.*|group.com.apple.*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Coerce a value to an integer (digits only). Empty becomes 0.
_leftovers_to_int() {
  local v="$1"
  v="${v//[^0-9]/}"
  [[ -n "$v" ]] && echo "$v" || echo "0"
}

# Best-effort repo root discovery (works whether sourced or executed).
_leftovers_repo_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # modules/ -> repo root
  echo "$(cd "${here}/.." && pwd)"
}


_leftovers_expand_path() {
  # Expand ~ and environment variables in a path string.
  local raw="$1"
  raw="${raw/#\~/$HOME}"
  # shellcheck disable=SC2086
  eval "printf '%s' \"$raw\""
}

# Confirm a move in a safe, dependency-tolerant way.
# Uses ask_gui if available (preferred), otherwise falls back to a terminal prompt.
_leftovers_confirm_move() {
  local p="$1"

  # If the shared GUI prompt exists, use it.
  if command -v ask_gui >/dev/null 2>&1; then
    ask_gui "${p}"
    return $?
  fi

  # Fallback: terminal prompt.
  local ans=""
  echo ""
  echo "Move this folder to backup?"
  echo "  ${p}"
  read -r -p "Type 'yes' to confirm: " ans
  [[ "$ans" == "yes" ]]
}

# Provide a targeted hint when macOS blocks moves from sandboxed locations.
_leftovers_move_hint() {
  local src="$1"

  # Sandbox / privacy-protected locations can trigger "Operation not permitted" even for user-owned data.
  case "$src" in
    "$HOME/Library/Containers/"*|"$HOME/Library/Group Containers/"*)
      echo "If this keeps failing: quit the related app, then grant Full Disk Access to your terminal (System Settings → Privacy & Security → Full Disk Access)."
      ;;
    *)
      echo ""
      ;;
  esac
}

# Move using the shared move contract from lib/fs.sh (move_attempt).
_leftovers_move_to_backup() {
  local src="$1"
  local backup_dir="$2"

  # This module must be run via mc-leaner.sh which sources lib/fs.sh.
  if ! command -v move_attempt >/dev/null 2>&1; then
    log "Leftovers: cannot move (move_attempt not available). Run via mc-leaner.sh, not the module directly."
    LEFTOVERS_MOVE_FAILURES+=("${src} | failed: move_attempt not available")
    return 1
  fi

  move_attempt "$src" "$backup_dir"

  case "${MOVE_LAST_STATUS:-failed}" in
    moved)
      # Defensive: some implementations accidentally surface stderr as a "dest" string.
      # Treat obvious mv error text as a failure.
      if echo "${MOVE_LAST_DEST:-}" | grep -Eqi 'permission denied|operation not permitted|mv:'; then
        local hint
        hint="$(_leftovers_move_hint "$src")"

        log "Leftovers: move failed (permission): ${MOVE_LAST_DEST}"
        [[ -n "$hint" ]] && log "Leftovers: hint: ${hint}"

        if [[ -n "$hint" ]]; then
          LEFTOVERS_MOVE_FAILURES+=("${src} | failed(permission): ${MOVE_LAST_DEST} | hint: ${hint}")
        else
          LEFTOVERS_MOVE_FAILURES+=("${src} | failed(permission): ${MOVE_LAST_DEST}")
        fi
        return 1
      fi

      log "Moved ${src} to backup: ${MOVE_LAST_DEST}"
      return 0
      ;;
    skipped)
      log "Leftovers: move skipped: ${MOVE_LAST_MESSAGE:-unknown reason}"
      LEFTOVERS_MOVE_FAILURES+=("${src} | skipped: ${MOVE_LAST_MESSAGE:-unknown reason}")
      return 1
      ;;
    failed|*)
      local hint
      hint="$(_leftovers_move_hint "$src")"

      # Special-case: macOS privacy controls (TCC) often block moves from ~/Library/Containers and ~/Library/Group Containers.
      # When this is the likely cause, emit a short, actionable hint right under the failure.
      local lower_msg
      lower_msg="${MOVE_LAST_MESSAGE:-}"
      lower_msg="$(echo "$lower_msg" | tr '[:upper:]' '[:lower:]' 2>/dev/null || echo "${MOVE_LAST_MESSAGE:-}")"

      log "Leftovers: move failed (${MOVE_LAST_CODE:-unknown}): ${MOVE_LAST_MESSAGE:-unknown error}"

      if echo "$lower_msg" | grep -Eq "operation not permitted|permission denied"; then
        log "Leftovers: hint: likely blocked by macOS privacy controls. Quit the related app, then grant Full Disk Access to your terminal (and VS Code if you use its integrated terminal), then retry."
      else
        [[ -n "$hint" && "${MOVE_LAST_CODE:-}" == "permission" ]] && log "Leftovers: hint: ${hint}"
      fi

      if echo "$lower_msg" | grep -Eq "operation not permitted|permission denied"; then
        LEFTOVERS_MOVE_FAILURES+=("${src} | failed(permission): ${MOVE_LAST_MESSAGE:-unknown error} | hint: Quit the related app, grant Full Disk Access to your terminal (and VS Code if used), then retry")
      else
        if [[ -n "$hint" && "${MOVE_LAST_CODE:-}" == "permission" ]]; then
          LEFTOVERS_MOVE_FAILURES+=("${src} | failed(permission): ${MOVE_LAST_MESSAGE:-unknown error} | hint: ${hint}")
        else
          LEFTOVERS_MOVE_FAILURES+=("${src} | failed(${MOVE_LAST_CODE:-unknown}): ${MOVE_LAST_MESSAGE:-unknown error}")
        fi
      fi
      return 1
      ;;
  esac
}

# -------------------------
# Public entrypoint
# -------------------------
run_leftovers_module() {
  local apply="$1"
  local backup_dir="$2"
  local explain="${3:-false}"
  local inventory_file="${4:-}"

  log "Leftovers: scanning user-level support locations (inspection-first)..."
  if [[ "$explain" == "true" ]]; then
    explain_log "Leftovers (explain): using inventory file: ${inventory_file}"
  fi

  LEFTOVERS_FLAGGED_COUNT=0
  LEFTOVERS_FLAGGED_ITEMS=()
  LEFTOVERS_MOVE_FAILURES=()

  if [[ -z "$inventory_file" || ! -f "$inventory_file" ]]; then
    if [[ "$explain" == "true" ]]; then
      explain_log "Leftovers: missing inventory file; skipping leftovers module."
    else
      log "Leftovers: missing inventory file; skipping."
    fi
    _leftovers_summary_emit
    return 0
  fi

  # Optional allowlist: exact paths to treat as eligible leftovers (inspection-first, reversible).
  local repo_root
  repo_root="$(_leftovers_repo_root)"
  local allowlist_file="${repo_root}/config/leftovers-allowlist.conf"
  if [[ "$explain" == "true" ]]; then
    if [[ -f "$allowlist_file" ]]; then
      explain_log "Leftovers: allowlist enabled at ${allowlist_file}"
    else
      explain_log "Leftovers: allowlist not found (optional): ${allowlist_file}"
    fi
  fi

  # Build a newline list of installed app bundle IDs from inventory (used to avoid false positives).
  # Inventory format (tab-separated): kind  source  name  bundle_id  path
  local installed_bundle_ids_file
  installed_bundle_ids_file="$(mktemp -t mcleaner_installed_bundle_ids.XXXXXX)"

  awk -F'\t' '($1=="app" && $4!="" ){print $4}' "$inventory_file" \
    | sort -u > "$installed_bundle_ids_file"

  if [[ "$explain" == "true" ]]; then
    local _n
    _n=$(wc -l < "$installed_bundle_ids_file" 2>/dev/null || echo "0")
    explain_log "Leftovers (explain): installed app bundle IDs loaded: ${_n}"
  fi

  local targets=()
  targets+=("$HOME/Library/Application Support")
  targets+=("$HOME/Library/Containers")
  targets+=("$HOME/Library/Group Containers")
  targets+=("$HOME/Library/Saved Application State")
  targets+=("$HOME/Library/Preferences")

  local min_mb=50
  local found_any="false"

  # Scan each target directory if it exists.
  local t
  for t in "${targets[@]}"; do
    [[ -d "$t" ]] || continue

    # Preferences: report-only for v1.4.0 (no moves).
    local prefs_report_only="false"
    if [[ "$t" == "$HOME/Library/Preferences" ]]; then
      prefs_report_only="true"
    fi

    if _leftovers_scan_target "$t" "$prefs_report_only" "$min_mb" "$apply" "$backup_dir" "$explain" "$installed_bundle_ids_file" "$allowlist_file"; then
      found_any="true"
    fi
  done

  if [[ "$found_any" != "true" || "${LEFTOVERS_FLAGGED_COUNT}" -eq 0 ]]; then
    log "Leftovers: no large leftovers found (by heuristics)."
    rm -f "$installed_bundle_ids_file" 2>/dev/null || true
    _leftovers_summary_emit
    return 0
  fi

  log "Leftovers: flagged ${LEFTOVERS_FLAGGED_COUNT} item(s)."

  # Print a compact summary at the end for legibility.
  log "Leftovers: flagged items:"
  local item
  for item in "${LEFTOVERS_FLAGGED_ITEMS[@]}"; do
    log "  - ${item}"
  done

  if [[ "$apply" == "true" && "${#LEFTOVERS_MOVE_FAILURES[@]}" -gt 0 ]]; then
    log "Leftovers: move failures:"
    for item in "${LEFTOVERS_MOVE_FAILURES[@]}"; do
      log "  - ${item}"
    done
  fi

  log "Leftovers: run with --apply to relocate selected leftovers (user-confirmed, reversible)."
  rm -f "$installed_bundle_ids_file" 2>/dev/null || true
  _leftovers_summary_emit
}

# -------------------------
# Internal helpers
# -------------------------

_leftovers_scan_target() {
  local target_dir="$1"
  local report_only="$2"
  local min_mb="$3"
  local apply="$4"
  local backup_dir="$5"
  local explain="$6"
  local installed_bundle_ids_file="$7"
  local allowlist_file="${8:-}"

  if [[ "$explain" == "true" ]]; then
    explain_log "Leftovers (explain): scanning ${target_dir}"
  fi

  # We intentionally limit to the first level to reduce false positives.
  # For Containers and Group Containers, items are usually top-level bundle IDs.
  local -a items
  items=()
  while IFS= read -r p; do
    [[ -n "$p" ]] && items+=("$p")
  done < <(find "$target_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)

  if [[ "${#items[@]}" -eq 0 ]]; then
    if [[ "$explain" == "true" ]]; then
      explain_log "Leftovers: no candidate folders found in ${target_dir}"
    fi
    return 1
  fi

  # Build normalized allowlist (absolute paths) for fast exact matching.
  # Format: one path per line; supports comments (# ...) and blank lines; supports ~ and env vars.
  local allowlist_norm_file=""
  if [[ -n "$allowlist_file" && -f "$allowlist_file" ]]; then
    allowlist_norm_file="$(mktemp -t mcleaner_leftovers_allowlist.XXXXXX)"
    while IFS= read -r line || [[ -n "$line" ]]; do
      # strip comments
      line="${line%%#*}"
      # trim spaces
      line="$(echo "$line" | awk '{$1=$1;print}')"
      [[ -z "$line" ]] && continue

      local expanded
      expanded="$(_leftovers_expand_path "$line")"

      # Only allow user-level Library paths for safety.
      case "$expanded" in
        "$HOME/Library/"* )
          echo "$expanded" >> "$allowlist_norm_file"
          ;;
        * )
          if [[ "$explain" == "true" ]]; then
            explain_log "Leftovers: ignore allowlist entry outside ~/Library: ${expanded}"
          fi
          ;;
      esac
    done < "$allowlist_file"
  fi

  local any_in_target="false"
  local p
  for p in "${items[@]}"; do
    local base
    base="$(basename "$p")"

    # Allowlist override: exact path match means "eligible leftover" even if small or not bundle-id.
    local is_allowlisted="false"
    if [[ -n "$allowlist_norm_file" && -f "$allowlist_norm_file" ]]; then
      if grep -qFx -- "$p" "$allowlist_norm_file" 2>/dev/null; then
        is_allowlisted="true"
      fi
    fi

    # Control skip explanation verbosity for Preferences scan in explain mode.
    local explain_skips="true"
    if [[ "$report_only" == "true" && "$is_allowlisted" != "true" ]]; then
      if ! _leftovers_looks_like_bundle_id "$base"; then
        explain_skips="false"
      fi
    fi

    # Protect Apple/system containers from being flagged (unless explicitly allowlisted).
    if [[ "$is_allowlisted" != "true" ]] && _leftovers_is_protected_owner "$base"; then
      if [[ "$explain" == "true" && "$explain_skips" == "true" ]]; then
        explain_log "Leftovers: skip (protected Apple/system owner): ${p}"
      fi
      continue
    fi

    # Heuristic: only consider bundle-id looking names in v1.4.0 unless allowlisted.
    # (com.vendor.App, net.vendor.App, org.vendor.App, etc)
    if [[ "$is_allowlisted" != "true" ]] && ! _leftovers_looks_like_bundle_id "$base"; then
      if [[ "$explain" == "true" && "$explain_skips" == "true" ]]; then
        explain_log "Leftovers: skip (non bundle-id name): ${p}"
      fi
      continue
    fi

    # Installed-match rule: if the folder name can be linked to an installed app, skip.
    # This handles Team ID prefixes and group container sub-identifiers.
    if [[ "$is_allowlisted" != "true" ]] && _leftovers_matches_installed "$base" "$installed_bundle_ids_file"; then
      if [[ "$explain" == "true" && "$explain_skips" == "true" ]]; then
        explain_log "Leftovers: skip (installed-match): ${base}"
      fi
      continue
    fi

    # Size threshold (bypass if allowlisted).
    local mb
    mb="$(_leftovers_to_int "$(_dir_mb "$p")")"
    if [[ "$is_allowlisted" != "true" ]] && [[ "$mb" -lt "$min_mb" ]]; then
      if [[ "$explain" == "true" && "$explain_skips" == "true" ]]; then
        explain_log "Leftovers: skip (below threshold ${min_mb}MB): ${mb}MB | ${p}"
      fi
      continue
    fi

    local mtime
    mtime="$(_path_mtime_human "$p")"

    any_in_target="true"

    log "LEFTOVER? ${mb}MB | modified: ${mtime} | owner: ${base} | path: ${p}"

    # Track for end-of-run summary.
    LEFTOVERS_FLAGGED_ITEMS+=("${mb}MB | modified: ${mtime} | owner: ${base} | ${p}")
    LEFTOVERS_FLAGGED_COUNT=$(( ${LEFTOVERS_FLAGGED_COUNT:-0} + 1 ))

    if [[ "$explain" == "true" ]]; then
      if [[ "$is_allowlisted" == "true" ]]; then
        explain_log "  reason: explicit allowlist match"
      else
        explain_log "  reason: folder name resembles bundle id; bundle id not found among installed apps"
        if [[ "$report_only" == "true" ]]; then
          explain_log "  note: Preferences is report-only in v1.4.0 (no moves)"
        fi
      fi
    fi

    # Optional relocation:
    # - By default, Preferences is report-only (no moves).
    # - Allowlisted paths are treated as explicit opt-in and may be relocated even from Preferences.
    if [[ "$apply" == "true" ]]; then
      if [[ "$report_only" == "true" && "$is_allowlisted" != "true" ]]; then
        :
      else
        if _leftovers_confirm_move "${p}"; then
          _leftovers_move_to_backup "$p" "$backup_dir" || true
        else
          if [[ "$explain" == "true" ]]; then
            explain_log "Leftovers: user declined move: ${p}"
          fi
        fi
      fi
    fi
  done

  if [[ -n "$allowlist_norm_file" && -f "$allowlist_norm_file" ]]; then
    rm -f "$allowlist_norm_file" 2>/dev/null || true
  fi

  [[ "$any_in_target" == "true" ]]
}

_leftovers_strip_team_prefix() {
  # Some group/container folders include an Apple Team ID prefix, e.g. UBF8T346G9.com.microsoft.teams
  # If present, strip "<TEAMID>." so we can match installed bundle IDs.
  local s="$1"
  if echo "$s" | grep -Eq '^[A-Z0-9]{10}\.'; then
    echo "${s#*.}"
  else
    echo "$s"
  fi
}

_leftovers_matches_installed() {
  # Returns 0 (true) when the owner/folder name can be linked to an installed bundle id.
  # This reduces false positives for container/group container sub-identifiers.
  #
  # Supported patterns:
  # - Exact match: com.vendor.App
  # - Team ID prefix: UBF8T346G9.com.vendor.App
  # - Group containers: group.com.vendor.App.shared (match by prefix)
  # - Combined: TEAMID.group.com.vendor.App.shared
  local raw="$1"
  local known_bundle_ids_file="$2"

  [[ -f "$known_bundle_ids_file" ]] || return 1

  local s
  s="$(_leftovers_strip_team_prefix "$raw")"

  # 1) Exact match first.
  if grep -qFx -- "$s" "$known_bundle_ids_file" 2>/dev/null; then
    return 0
  fi

  # 2) Prefix match for sub-identifiers (e.g. com.getdropbox.dropbox.sync).
  local id
  while IFS= read -r id || [[ -n "$id" ]]; do
    [[ -z "$id" ]] && continue
    if [[ "$s" == "$id".* ]]; then
      return 0
    fi
  done < "$known_bundle_ids_file"

  # 3) Group containers: strip "group." and try again (prefix match).
  if [[ "$s" == group.* ]]; then
    local remainder
    remainder="${s#group.}"

    if grep -qFx -- "$remainder" "$known_bundle_ids_file" 2>/dev/null; then
      return 0
    fi

    while IFS= read -r id || [[ -n "$id" ]]; do
      [[ -z "$id" ]] && continue
      if [[ "$remainder" == "$id".* ]]; then
        return 0
      fi
    done < "$known_bundle_ids_file"
  fi

  return 1
}

_leftovers_looks_like_bundle_id() {
  # Conservative pattern: at least 2 dots, only [A-Za-z0-9._-]
  # Examples: com.google.Chrome, net.whatsapp.WhatsApp, org.mozilla.firefox
  local s="$1"
  echo "$s" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9._-]*\.[A-Za-z0-9._-]+$'
}

_dir_mb() {
  # Purpose: return directory size in MB (integer)
  # Notes: macOS du supports -sk (KiB)
  local p="$1"
  local kb
  kb=$(du -sk "$p" 2>/dev/null | awk '{print $1}' || echo "0")
  echo $((kb / 1024))
}

_path_mtime_human() {
  # Purpose: best-effort mtime in local time
  local p="$1"
  local epoch
  epoch=$(stat -f "%m" "$p" 2>/dev/null || echo "")
  if [[ -z "$epoch" ]]; then
    echo "unknown"
  else
    date -r "$epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown"
  fi
}