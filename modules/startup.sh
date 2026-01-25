#!/bin/bash
# shellcheck shell=bash
# mc-leaner: startup
# Purpose: Inspect macOS startup execution surfaces (launchd + login items) for visibility.
# Safety: Inspection-only (never modifies system state). In clean/apply mode, it still only scans.

set -o pipefail

# ----------------------------------------------------------------------------
# Logging fallbacks (when module is run standalone)
# ----------------------------------------------------------------------------

if ! declare -F log_info >/dev/null 2>&1; then
  log_info() { echo "$*"; }
fi

if ! declare -F log_explain >/dev/null 2>&1; then
  log_explain() { echo "EXPLAIN: $*"; }
fi

# -----------------------------------------------------------------------------
# Explain helper
# -----------------------------------------------------------------------------

_startup_explain() {
  local explain="$1"; shift || true
  [[ "${explain}" == "true" ]] || return 0

  # Project runner is expected to provide log_explain; fall back to log_info if needed.
  if declare -F log_explain >/dev/null 2>&1; then
    log_explain "$@"
  else
    log_info "EXPLAIN: $*"
  fi
}

# -----------------------------------------------------------------------------
# Attribution helpers
# -----------------------------------------------------------------------------

_startup_is_apple_owner() {
  # Apple-owned identifiers (best-effort).
  local label="$1"
  [[ "${label}" == com.apple.* ]] && return 0
  [[ "${label}" == group.com.apple.* ]] && return 0
  [[ "${label}" == *.apple.* ]] && return 0
  return 1
}

_startup_infer_timing_from_plist() {
  # Heuristic timing: boot | login | on-demand.
  local plist="$1"

  if [[ "${plist}" == /Library/LaunchDaemons/* || "${plist}" == /System/Library/LaunchDaemons/* ]]; then
    echo "boot"
    return 0
  fi

  # Agents are usually login unless clearly on-demand.
  # Infer on-demand when BOTH RunAtLoad and KeepAlive are absent.
  local runatload="" keepalive=""
  runatload="$(/usr/bin/defaults read "${plist}" RunAtLoad 2>/dev/null || true)"
  keepalive="$(/usr/bin/defaults read "${plist}" KeepAlive 2>/dev/null || true)"

  if [[ -z "${runatload}" && -z "${keepalive}" ]]; then
    echo "on-demand"
  else
    echo "login"
  fi
}

_startup_plist_label() {
  # Best-effort: Label key or plist basename.
  local plist="$1"
  local label=""

  label="$(/usr/bin/defaults read "${plist}" Label 2>/dev/null || true)"
  if [[ -n "${label}" ]]; then
    echo "${label}"
  else
    basename "${plist}" | sed 's/\.plist$//'
  fi
}

_startup_plist_exec() {
  # Best-effort: Program or first ProgramArguments element.
  local plist="$1"
  local program="" argv0=""

  program="$(/usr/bin/defaults read "${plist}" Program 2>/dev/null || true)"
  if [[ -n "${program}" ]]; then
    echo "${program}"
    return 0
  fi

  # defaults read returns newline-delimited items for arrays; grab first non-empty token.
  argv0="$(/usr/bin/defaults read "${plist}" ProgramArguments 2>/dev/null | head -n 1 | sed 's/^\s*//;s/\s*$//' || true)"
  if [[ -n "${argv0}" ]]; then
    echo "${argv0}"
    return 0
  fi

  echo ""
}

_startup_inventory_owner() {
  # Attribution (inventory-first when available).
  # Output: "<owner>|<how>|<confidence>".
  local label="$1"
  local exec_path="$2"

  if _startup_is_apple_owner "${label}"; then
    echo "Apple (system)|label-prefix|high"
    return 0
  fi

  local owner=""

  if declare -F inventory_lookup_owner_by_bundle_id >/dev/null 2>&1; then
    owner="$(inventory_lookup_owner_by_bundle_id "${label}" 2>/dev/null || true)"
    if [[ -n "${owner}" ]]; then
      echo "${owner}|bundle-id|high"
      return 0
    fi
  fi

  if declare -F inventory_lookup_owner_by_path >/dev/null 2>&1 && [[ -n "${exec_path}" ]]; then
    owner="$(inventory_lookup_owner_by_path "${exec_path}" 2>/dev/null || true)"
    if [[ -n "${owner}" ]]; then
      echo "${owner}|path|high"
      return 0
    fi
  fi

  if declare -F inventory_lookup_owner_by_name >/dev/null 2>&1; then
    owner="$(inventory_lookup_owner_by_name "${label}" 2>/dev/null || true)"
    if [[ -n "${owner}" ]]; then
      echo "${owner}|name|medium"
      return 0
    fi
  fi

  if declare -F inventory_lookup_brew_service_owner >/dev/null 2>&1; then
    owner="$(inventory_lookup_brew_service_owner "${label}" 2>/dev/null || true)"
    if [[ -n "${owner}" ]]; then
      echo "Homebrew (${owner})|brew-service|medium"
      return 0
    fi
  fi

  echo "Unknown|none|low"
}

# -----------------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------------

_startup_emit_item() {
  # Inputs: explain timing source label exec_path owner how conf
  local explain="$1" timing="$2" source="$3" label="$4" exec_path="$5" owner="$6" how="$7" conf="$8"

  if [[ -z "${exec_path}" ]]; then
    exec_path="-"
  fi

  log_info "STARTUP? ${timing} | source: ${source} | owner: ${owner} | conf: ${conf} | label: ${label} | exec: ${exec_path}"
  _startup_explain "${explain}" "Startup item | timing=${timing} | source=${source} | label=${label} | exec=${exec_path} | attribution=${how} | confidence=${conf}"
}

# -----------------------------------------------------------------------------
# Collectors
# -----------------------------------------------------------------------------

_startup_scan_launchd_dir() {
  # Inputs: explain dir source
  local explain="$1" dir="$2" source="$3"
  [[ -d "${dir}" ]] || return 0

  local plist="" label="" exec_path="" timing="" owner_meta="" owner="" how="" conf=""

  while IFS= read -r -d '' plist; do
    label="$(_startup_plist_label "${plist}")"
    exec_path="$(_startup_plist_exec "${plist}")"
    timing="$(_startup_infer_timing_from_plist "${plist}")"

    owner_meta="$(_startup_inventory_owner "${label}" "${exec_path}")"
    owner="${owner_meta%%|*}"
    how="${owner_meta#*|}"; how="${how%%|*}"
    conf="${owner_meta##*|}"

    _startup_emit_item "${explain}" "${timing}" "${source}" "${label}" "${exec_path}" "${owner}" "${how}" "${conf}"

    STARTUP_CHECKED=$((STARTUP_CHECKED + 1))

    # Flagging rules (visibility only):
    # - Never flag Apple system
    # - Suppress unknown flags for /System/Library/LaunchDaemons
    # - Flag only Unknown owners
    if [[ "${owner}" == "Unknown" ]]; then
      if [[ "${plist}" == /System/Library/LaunchDaemons/* ]]; then
        _startup_explain "${explain}" "Startup flag suppressed | reason=system-domain | plist=${plist}"
      else
        STARTUP_FLAGGED=$((STARTUP_FLAGGED + 1))
        STARTUP_UNKNOWN=$((STARTUP_UNKNOWN + 1))
      fi
    fi

  done < <(find "${dir}" -maxdepth 1 -type f -name '*.plist' -print0 2>/dev/null)
}

_startup_scan_login_items() {
  # Best-effort: if osascript is unavailable or fails, skip.
  local explain="$1"

  if [[ ! -x /usr/bin/osascript ]]; then
    _startup_explain "${explain}" "Startup: Login Items: osascript not available; skipping"
    return 0
  fi

  local items
  items="$(/usr/bin/osascript 2>/dev/null <<'APPLESCRIPT'
try
  tell application "System Events"
    set loginItems to every login item
    repeat with li in loginItems
      set nm to the name of li
      if nm is not missing value then
        do shell script "echo " & quoted form of nm
      end if
    end repeat
  end tell
end try
APPLESCRIPT
)" || true

  [[ -n "${items}" ]] || return 0

  local line="" label="" exec_path="" timing="login" owner_meta="" owner="" how="" conf=""

  while IFS= read -r line; do
    label="${line}"
    exec_path="" # Not reliably obtainable without additional calls.

    owner_meta="$(_startup_inventory_owner "${label}" "${exec_path}")"
    owner="${owner_meta%%|*}"
    how="${owner_meta#*|}"; how="${how%%|*}"
    conf="${owner_meta##*|}"

    _startup_emit_item "${explain}" "${timing}" "LoginItem" "${label}" "${exec_path}" "${owner}" "${how}" "${conf}"

    STARTUP_CHECKED=$((STARTUP_CHECKED + 1))
    if [[ "${owner}" == "Unknown" ]]; then
      STARTUP_FLAGGED=$((STARTUP_FLAGGED + 1))
      STARTUP_UNKNOWN=$((STARTUP_UNKNOWN + 1))
    fi

  done <<<"${items}"
}

# -----------------------------------------------------------------------------
# Entrypoint
# -----------------------------------------------------------------------------

run_startup_module() {
  # Contract: run_startup_module <mode> <apply> <backup_dir> <explain> [inventory_index]
  local mode="${1:-scan}"
  local apply="${2:-false}"
  local backup_dir="${3:-}"
  local explain="${4:-false}"
  local inventory_index="${5:-}"

  : "${backup_dir}" "${inventory_index}" # reserved for contract consistency

  STARTUP_CHECKED=${STARTUP_CHECKED:-0}
  STARTUP_FLAGGED=${STARTUP_FLAGGED:-0}
  STARTUP_UNKNOWN=${STARTUP_UNKNOWN:-0}

  STARTUP_CHECKED=0
  STARTUP_FLAGGED=0
  STARTUP_UNKNOWN=0

  if [[ "${mode}" == "clean" || "${apply}" == "true" ]]; then
    _startup_explain "${explain}" "Startup: clean/apply requested, but startup is inspection-only; running scan"
  fi

  _startup_explain "${explain}" "Startup: scanning launchd + login items"

  _startup_scan_launchd_dir "${explain}" "${HOME}/Library/LaunchAgents" "LaunchAgent"
  _startup_scan_launchd_dir "${explain}" "/Library/LaunchAgents" "LaunchAgent"

  _startup_scan_launchd_dir "${explain}" "/Library/LaunchDaemons" "LaunchDaemon"
  _startup_scan_launchd_dir "${explain}" "/System/Library/LaunchDaemons" "LaunchDaemon"

  _startup_scan_login_items "${explain}"

  log_info "Startup: inspected ${STARTUP_CHECKED} item(s); flagged ${STARTUP_FLAGGED} (unknown owner ${STARTUP_UNKNOWN})"
}
