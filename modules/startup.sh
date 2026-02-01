#!/bin/bash
# shellcheck shell=bash
# mc-leaner: startup
# Purpose: Inspect macOS startup execution surfaces (launchd + login items) for visibility.
# Safety: Inspection-only (never modifies system state). In clean/apply mode, it still only scans.
# NOTE: Modules run with strict mode for deterministic failures and auditability.

set -euo pipefail

# Suppress SIGPIPE noise when output is piped to a consumer that exits early (e.g., `head -n`).
# Safety: logging/output ergonomics only; does not affect inspection results.
trap '' PIPE

# Contract: run_startup_module <mode> <apply> <backup_dir> <explain> [inventory_index]
# Note: Kept near the top so simple greps and partial prints (e.g., `sed -n '1,260p'`) will find it.

# ----------------------------
# Contract: startup output + summary (v2.2.0+)
# ----------------------------
# Safety: inspection-only. `mode=clean` and `apply=true` still scan only.
#
# Item format:
#   STARTUP? <timing> | source: <source> | owner: <owner> | conf: <conf> | impact: <impact> | label: <label> | exec: <exec>
#
# Exports (for RUN SUMMARY):
#   STARTUP_CHECKED_COUNT
#   STARTUP_FLAGGED_COUNT
#   STARTUP_BOOT_FLAGGED_COUNT
#   STARTUP_LOGIN_FLAGGED_COUNT
#   STARTUP_FLAGGED_IDS_LIST (newline-delimited)
#   STARTUP_DUR_S (best-effort seconds)
#   STARTUP_ESTIMATED_RISK (low|medium|high)

# ----------------------------
# Defensive Checks
# ----------------------------
# Purpose: Provide safe fallbacks when shared helpers are not loaded.
# Safety: Logging only; must not change inspection behavior.

if ! command -v log >/dev/null 2>&1; then
  log() {
    # Ignore EPIPE when downstream closes early (e.g., `head -n`, `rg -m`).
    { printf '%s\n' "$*"; } 2>/dev/null || true
  }
fi

if ! command -v explain_log >/dev/null 2>&1; then
  explain_log() {
    # Purpose: Best-effort verbose logging when --explain is enabled.
    # Safety: Logging only.
    if [[ "${EXPLAIN:-false}" == "true" ]]; then
      log "$@"
    fi
  }
fi


# Ensure shared SERVICE? emitter is available (label-deduped, network-facing heuristics).
if ! command -v service_emit_record >/dev/null 2>&1; then
  _startup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  [[ -f "${_startup_dir}/../lib/utils.sh" ]] && source "${_startup_dir}/../lib/utils.sh"
fi

# Final fallback: if service_emit_record is still unavailable, define a no-op.
# Safety: preserves inspection output (STARTUP?) while skipping SERVICE? emission.
if ! command -v service_emit_record >/dev/null 2>&1; then
  service_emit_record() { return 0; }
fi

# ----------------------------
# Explain helper
# ----------------------------
_startup_explain() {
  local explain="$1"; shift || true
  [[ "${explain}" == "true" ]] || return 0

  # Runner is expected to provide explain_log; fall back to log when needed.
  if command -v explain_log >/dev/null 2>&1; then
    explain_log "$@"
  else
    log "EXPLAIN: $*"
  fi
}

# ----------------------------
# Attribution helpers
# ----------------------------
_startup_is_apple_owner() {
  # Apple-owned identifiers (best-effort).
  # Keep this strict to avoid mis-attributing third-party items that merely contain "apple".
  local label="$1"
  [[ "${label}" == com.apple.* ]] && return 0
  [[ "${label}" == group.com.apple.* ]] && return 0
  return 1
}

# Conservative static owner attribution for known label prefixes (no fuzzy matching)
_startup_label_prefix_owner() {
  # Purpose: Conservative static owner attribution when inventory cannot resolve a label.
  # Safety: Explicit mapping only (no fuzzy matching). Intended to reduce Unknown for common vendors.
  # Output: "<owner>|label-prefix-map|medium" or empty string when no match.
  local label="$1"

  case "$label" in
    com.dropbox.*)
      echo "Dropbox|label-prefix-map|medium"
      return 0
      ;;
    us.zoom.*)
      echo "Zoom|label-prefix-map|medium"
      return 0
      ;;
    com.malwarebytes.*)
      echo "Malwarebytes|label-prefix-map|medium"
      return 0
      ;;
    com.bitdefender.*)
      echo "Bitdefender|label-prefix-map|medium"
      return 0
      ;;
    com.google.keystone.*|com.google.GoogleUpdater.*)
      echo "Google Keystone|label-prefix-map|medium"
      return 0
      ;;
    *)
      :
      ;;
  esac

  echo ""
}

_startup_plist_extract_raw() {
  # Usage: _startup_plist_extract_raw <plist> <keypath>
  # Returns the value as a raw scalar when possible, otherwise empty.
  local plist="$1" keypath="$2"
  /usr/bin/plutil -extract "${keypath}" raw -o - "${plist}" 2>/dev/null || true
}

_startup_plist_extract_xml() {
  # Usage: _startup_plist_extract_xml <plist> <keypath>
  # Returns an XML representation (useful for dict/array/bool presence checks), otherwise empty.
  local plist="$1" keypath="$2"
  /usr/bin/plutil -extract "${keypath}" xml1 -o - "${plist}" 2>/dev/null || true
}

# Conservative full-plist XML fallback helpers
_startup_plist_to_xml() {
  # Usage: _startup_plist_to_xml <plist>
  # Purpose: Convert a plist to XML for fallback parsing.
  # Safety: Read-only.
  local plist="$1"
  /usr/bin/plutil -convert xml1 -o - "${plist}" 2>/dev/null || true
}


_startup_infer_timing_from_plist() {
  # Heuristic timing: boot | login | on-demand.
  local plist="$1"

  if [[ "${plist}" == /Library/LaunchDaemons/* || "${plist}" == /System/Library/LaunchDaemons/* ]]; then
    echo "boot"
    return 0
  fi

  # Agents are usually login unless clearly on-demand.
  # Infer on-demand when BOTH RunAtLoad and KeepAlive keys are absent.
  local runatload="" keepalive_xml=""
  runatload="$(_startup_plist_extract_raw "${plist}" RunAtLoad | tr -d '[:space:]')"
  keepalive_xml="$(_startup_plist_extract_xml "${plist}" KeepAlive)"

  if [[ -z "${runatload}" && -z "${keepalive_xml}" ]]; then
    echo "on-demand"
  else
    echo "login"
  fi
}

_startup_plist_label() {
  # Best-effort: Label key or plist basename.
  local plist="$1"
  local label=""

  label="$(_startup_plist_extract_raw "${plist}" Label | sed 's/^\s*//;s/\s*$//')"
  if [[ -n "${label}" ]]; then
    { printf '%s\n' "${label}"; } 2>/dev/null || true
  else
    { basename "${plist}" | sed 's/\.plist$//'; } 2>/dev/null || true
  fi
}

_startup_plist_exec() {
  # Best-effort: Program or first ProgramArguments element.
  # Performance: keep raw plutil extracts on the fast path; only convert to full XML once if needed.
  local plist="$1"
  local program="" argv0="" xml=""

  program="$(_startup_plist_extract_raw "${plist}" Program | sed 's/^\s*//;s/\s*$//')"
  if [[ -n "${program}" ]]; then
    { printf '%s\n' "${program}"; } 2>/dev/null || true
    return 0
  fi

  # Use ProgramArguments[0] when present.
  argv0="$(_startup_plist_extract_raw "${plist}" ProgramArguments.0 | sed 's/^\s*//;s/\s*$//')"
  if [[ -n "${argv0}" ]]; then
    { printf '%s\n' "${argv0}"; } 2>/dev/null || true
    return 0
  fi

  # Fallback: some plists use BundleProgram.
  program="$(_startup_plist_extract_raw "${plist}" BundleProgram | sed 's/^\s*//;s/\s*$//')"
  if [[ -n "${program}" ]]; then
    { printf '%s\n' "${program}"; } 2>/dev/null || true
    return 0
  fi

  # Fallback: XPC services sometimes declare a ServiceExecutable.
  program="$(_startup_plist_extract_raw "${plist}" XPCService.ServiceExecutable | sed 's/^\s*//;s/\s*$//')"
  if [[ -n "${program}" ]]; then
    { printf '%s\n' "${program}"; } 2>/dev/null || true
    return 0
  fi

  # Next fallback: targeted XML extraction for ProgramArguments (avoid full-plist conversion when possible).
  # Behavior: best-effort only; preserves existing precedence and outputs.
  local pa_xml=""
  pa_xml="$(_startup_plist_extract_xml \"${plist}\" ProgramArguments)"
  if [[ -n "${pa_xml}" ]]; then
    argv0="$({ printf '%s' "${pa_xml}"; } 2>/dev/null | sed -n 's/.*<string>\([^<]*\)<\/string>.*/\1/p; q' 2>/dev/null || true)"
    argv0="$(printf '%s' "${argv0}" | sed 's/^\s*//;s/\s*$//')"
    if [[ -n "${argv0}" ]]; then
      { printf '%s\n' "${argv0}"; } 2>/dev/null || true
      return 0
    fi
  fi

  # Final fallback: convert the plist to XML once and do best-effort parsing.
  xml="$(_startup_plist_to_xml "${plist}")"
  if [[ -n "${xml}" ]]; then
    program="$({ printf '%s' "${xml}"; } 2>/dev/null \
      | sed -n 's/.*<key>Program<\/key>[[:space:]]*<string>\([^<]*\)<\/string>.*/\1/p; q' 2>/dev/null \
      || true)"
    program="$(printf '%s' "${program}" | sed 's/^\s*//;s/\s*$//')"
    if [[ -n "${program}" ]]; then
      { printf '%s\n' "${program}"; } 2>/dev/null || true
      return 0
    fi

    argv0="$({ printf '%s' "${xml}"; } 2>/dev/null \
      | tr '\n' ' ' 2>/dev/null \
      | sed -n 's/.*<key>ProgramArguments<\/key>[[:space:]]*<array>\(.*\)<\/array>.*/\1/p' 2>/dev/null \
      | sed -n 's/.*<string>\([^<]*\)<\/string>.*/\1/p; q' 2>/dev/null \
      || true)"
    argv0="$(printf '%s' "${argv0}" | sed 's/^\s*//;s/\s*$//')"
    if [[ -n "${argv0}" ]]; then
      { printf '%s\n' "${argv0}"; } 2>/dev/null || true
      return 0
    fi

    program="$({ printf '%s' "${xml}"; } 2>/dev/null \
      | sed -n 's/.*<key>ServiceExecutable<\/key>[[:space:]]*<string>\([^<]*\)<\/string>.*/\1/p; q' 2>/dev/null \
      || true)"
    program="$(printf '%s' "${program}" | sed 's/^\s*//;s/\s*$//')"
    if [[ -n "${program}" ]]; then
      { printf '%s\n' "${program}"; } 2>/dev/null || true
      return 0
    fi
  fi

  { printf '%s\n' ""; } 2>/dev/null || true
}

_startup_inventory_owner() {
  # Attribution (inventory-first when available).
  # Output: "<owner>|<how>|<confidence>".
  local label="$1"
  local exec_path="$2"

  if _startup_is_apple_owner "${label}"; then
    { printf '%s\n' "Apple (system)|label-prefix|high"; } 2>/dev/null || true
    return 0
  fi

  local owner=""

  if declare -F inventory_lookup_owner_by_bundle_id >/dev/null 2>&1; then
    owner="$(inventory_lookup_owner_by_bundle_id "${label}" 2>/dev/null || true)"
    if [[ -n "${owner}" ]]; then
      { printf '%s\n' "${owner}|bundle-id|high"; } 2>/dev/null || true
      return 0
    fi
  fi

  if declare -F inventory_lookup_owner_by_path >/dev/null 2>&1 && [[ -n "${exec_path}" ]]; then
    owner="$(inventory_lookup_owner_by_path "${exec_path}" 2>/dev/null || true)"
    if [[ -n "${owner}" ]]; then
      { printf '%s\n' "${owner}|path|high"; } 2>/dev/null || true
      return 0
    fi
  fi

  if declare -F inventory_lookup_owner_by_name >/dev/null 2>&1; then
    owner="$(inventory_lookup_owner_by_name "${label}" 2>/dev/null || true)"
    if [[ -n "${owner}" ]]; then
      { printf '%s\n' "${owner}|name|medium"; } 2>/dev/null || true
      return 0
    fi
  fi

  if declare -F inventory_lookup_brew_service_owner >/dev/null 2>&1; then
    owner="$(inventory_lookup_brew_service_owner "${label}" 2>/dev/null || true)"
    if [[ -n "${owner}" ]]; then
      { printf '%s\n' "Homebrew (${owner})|brew-service|medium"; } 2>/dev/null || true
      return 0
    fi
  fi

  # Generic fallback: match launchd label prefixes against installed bundle IDs in the inventory index.
  if declare -F inventory_owner_by_label_prefix >/dev/null 2>&1; then
    local prefix_meta=""
    prefix_meta="$(inventory_owner_by_label_prefix "${label}" "${INVENTORY_INDEX_FILE:-}" 2>/dev/null || true)"
    if [[ -n "${prefix_meta}" ]]; then
      local p_owner="" p_how="" p_conf=""
      p_owner="${prefix_meta%%$'\t'*}"
      p_how="${prefix_meta#*$'\t'}"; p_how="${p_how%%$'\t'*}"
      p_conf="${prefix_meta##*$'\t'}"
      { printf '%s\n' "${p_owner}|${p_how}|${p_conf}"; } 2>/dev/null || true
      return 0
    fi
  fi

  # Fallback: explicit label-prefix owner map (static; not inventory-backed).
  local mapped=""
  mapped="$(_startup_label_prefix_owner "${label}")"
  if [[ -n "$mapped" ]]; then
    { printf '%s\n' "$mapped"; } 2>/dev/null || true
    return 0
  fi

  { printf '%s\n' "Unknown|none|low"; } 2>/dev/null || true
}

# ----------------------------
# Impact scoring (v2.2.0)
# ----------------------------
_startup_lc() {
  # Lowercase helper (bash 3.2 compatible)
  { printf '%s\n' "$1"; } 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

_startup_infer_impact() {
  # Best-effort impact attribution. Output: low | medium | high
  # Inputs: timing label exec_path owner conf
  local timing="$1" label="$2" exec_path="$3" owner="$4" conf="$5"

  local score=0

  # Timing
  case "${timing}" in
    boot) score=$((score + 3)) ;;
    login) score=$((score + 2)) ;;
    on-demand) score=$((score + 0)) ;;
    *) score=$((score + 0)) ;;
  esac

  # Ownership / trust
  if [[ "${owner}" == "Apple (system)" && "${conf}" == "high" ]]; then
    score=$((score - 4))
  elif [[ "${owner}" == "Unknown" ]]; then
    score=$((score + 3))
  else
    case "${conf}" in
      low) score=$((score + 2)) ;;
      medium) score=$((score + 1)) ;;
      *) : ;;
    esac
  fi

  # Binary location (exec path)
  if [[ -z "${exec_path}" || "${exec_path}" == "-" ]]; then
    score=$((score + 1))
  elif [[ "${exec_path}" == /System/* || "${exec_path}" == /usr/libexec/* ]]; then
    score=$((score - 2))
  elif [[ "${exec_path}" == /Applications/* ]]; then
    score=$((score + 1))
  elif [[ "${exec_path}" == /Users/* || "${exec_path}" == /Library/* ]]; then
    score=$((score + 2))
  fi

  # Known heavy categories (take max; do not sum)
  local hay="$( _startup_lc "${label} ${exec_path}" )"
  local cat=0

  # virtualization
  if echo "${hay}" | grep -Eq '(vmware|virtualbox|parallels|qemu|utm)'; then
    cat=3
  # sync / backup / cloud drive
  elif echo "${hay}" | grep -Eq '(dropbox|onedrive|google drive|googledrive|box|nextcloud|sync)'; then
    cat=2
  # security / endpoint / vpn
  elif echo "${hay}" | grep -Eq '(crowdstrike|falcon|sentinelone|carbonblack|defender|symantec|sophos|antivirus|malware|vpn|zscaler|globalprotect|paloalto)'; then
    cat=2
  # dev tooling
  elif echo "${hay}" | grep -Eq '(docker|k8s|kubernetes|colima|rancher|homebrew|brew)'; then
    cat=1
  fi

  score=$((score + cat))

  # Map score to impact
  local impact="low"
  if [[ ${score} -ge 6 ]]; then
    impact="high"
  elif [[ ${score} -ge 2 ]]; then
    impact="medium"
  fi

  # Caps and overrides
  if [[ "${timing}" == "on-demand" && "${impact}" == "high" ]]; then
    impact="medium"
  fi

  if [[ ( -z "${exec_path}" || "${exec_path}" == "-" ) && "${owner}" != "Unknown" && "${impact}" == "high" ]]; then
    impact="medium"
  fi

  if [[ "${owner}" == "Apple (system)" && "${conf}" == "high" && "${impact}" == "high" ]]; then
    impact="medium"
  fi

  if [[ "${owner}" == "Unknown" && "${timing}" == "boot" ]]; then
    impact="high"
  fi

  echo "${impact}"
}

# ----------------------------
# Output
# ----------------------------
_startup_emit_item() {
  # Inputs: explain timing source label exec_path owner how conf impact
  local explain="$1" timing="$2" source="$3" label="$4" exec_path="$5" owner="$6" how="$7" conf="$8" impact="$9"

  if [[ -z "${exec_path}" ]]; then
    exec_path="-"
  fi

  if [[ -z "${impact}" ]]; then
    impact="low"
  fi

  log "STARTUP? ${timing} | source: ${source} | owner: ${owner} | conf: ${conf} | impact: ${impact} | label: ${label} | exec: ${exec_path}"
  _startup_explain "${explain}" "Startup item | timing=${timing} | source=${source} | label=${label} | exec=${exec_path} | attribution=${how} | confidence=${conf}"
}

# ----------------------------
# Collectors
# ----------------------------
_startup_scan_launchd_dir() {
  # Inputs: explain dir source
  local explain="$1" dir="$2" source="$3"
  [[ -d "${dir}" ]] || return 0

  local plist="" label="" exec_path="" timing="" owner_meta="" owner="" how="" conf="" scope=""

  # Compute scope once per directory
  case "${dir}" in
    /Library/*|/System/Library/*)
      scope="system"
      ;;
    "${HOME}"/*)
      scope="user"
      ;;
    *)
      scope="user"
      ;;
  esac

  while IFS= read -r -d '' plist; do
    label="$(_startup_plist_label "${plist}")"
    exec_path="$(_startup_plist_exec "${plist}")"
    timing="$(_startup_infer_timing_from_plist "${plist}")"

    owner_meta="$(_startup_inventory_owner "${label}" "${exec_path}")"
    owner="${owner_meta%%|*}"
    how="${owner_meta#*|}"; how="${how%%|*}"
    conf="${owner_meta##*|}"

    local impact=""
    impact="$(_startup_infer_impact "${timing}" "${label}" "${exec_path}" "${owner}" "${conf}")"

    _startup_emit_item "${explain}" "${timing}" "${source}" "${label}" "${exec_path}" "${owner}" "${how}" "${conf}" "${impact}"

    # Emit SERVICE? v2.3.0 contract-lock record (shared emitter: scope persistence owner network_facing label)
    service_emit_record "${scope}" "${timing}" "${owner}" "" "${label}"

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
        STARTUP_FLAGGED_IDS+=("${label:-$plist}")

        if [[ "${impact}" == "high" ]]; then
          STARTUP_IMPACT_HIGH=$((STARTUP_IMPACT_HIGH + 1))
        fi

        # Surface breakdown for run summary
        # Treat "on-demand" as login surface for summary purposes.
        if [[ "${timing}" == "boot" ]]; then
          STARTUP_BOOT_FLAGGED=$((STARTUP_BOOT_FLAGGED + 1))
        else
          STARTUP_LOGIN_FLAGGED=$((STARTUP_LOGIN_FLAGGED + 1))
        fi
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
    [[ -n "${line}" ]] || continue

    label="${line}"
    exec_path="" # Not reliably obtainable without additional calls.

    owner_meta="$(_startup_inventory_owner "${label}" "${exec_path}")"
    owner="${owner_meta%%|*}"
    how="${owner_meta#*|}"; how="${how%%|*}"
    conf="${owner_meta##*|}"

    # Conservative fallback for LoginItems: exact label mapping (explicit only).
    if [[ "${owner}" == "Unknown" ]]; then
      case "${label}" in
        Dropbox)
          owner="Dropbox"
          how="label-exact-map"
          conf="medium"
          ;;
        *)
          :
          ;;
      esac
    fi

    local impact=""
    impact="$(_startup_infer_impact "${timing}" "${label}" "${exec_path}" "${owner}" "${conf}")"

    _startup_emit_item "${explain}" "${timing}" "LoginItem" "${label}" "${exec_path}" "${owner}" "${how}" "${conf}" "${impact}"

    # Emit SERVICE? v2.3.0 contract-lock record for login items (shared emitter: scope persistence owner network_facing label)
    service_emit_record "user" "login" "${owner}" "" "${label}"

    STARTUP_CHECKED=$((STARTUP_CHECKED + 1))
    if [[ "${owner}" == "Unknown" ]]; then
      STARTUP_FLAGGED=$((STARTUP_FLAGGED + 1))
      STARTUP_UNKNOWN=$((STARTUP_UNKNOWN + 1))
      STARTUP_FLAGGED_IDS+=("${label}")
      STARTUP_LOGIN_FLAGGED=$((STARTUP_LOGIN_FLAGGED + 1))
      if [[ "${impact}" == "high" ]]; then
        STARTUP_IMPACT_HIGH=$((STARTUP_IMPACT_HIGH + 1))
      fi
    fi
  done <<<"${items}"
}

# ----------------------------
# Entrypoint
# ----------------------------
run_startup_module() {
  local mode="${1:-scan}"
  local apply="${2:-false}"
  local backup_dir="${3:-}"
  local explain="${4:-false}"
  local inventory_index="${5:-}"

  # Inputs
  log "Startup: mode=${mode} apply=${apply} backup_dir=${backup_dir} explain=${explain} inventory_index=${inventory_index:-<none>}"

  # Explain flag used throughout via EXPLAIN.
  local _startup_prev_explain="${EXPLAIN:-false}"
  EXPLAIN="${explain}"

  : "${mode}" "${backup_dir}" "${inventory_index}" # reserved for contract consistency

  # Inventory index (if provided by runner) for attribution helpers.
  local _startup_prev_inventory_index_file="${INVENTORY_INDEX_FILE:-}"
  if [[ -n "${inventory_index}" ]]; then
    INVENTORY_INDEX_FILE="${inventory_index}"
    export INVENTORY_INDEX_FILE
  fi

  # Timing (best-effort wall clock duration for this module).
  local _startup_t0="" _startup_t1=""
  _startup_t0="$(/bin/date +%s 2>/dev/null || echo '')"
  STARTUP_DUR_S=0

  _startup_finish_timing() {
    # SAFETY: must be safe under `set -u` and when invoked on early returns.
    _startup_t1="$(/bin/date +%s 2>/dev/null || echo '')"
    if [[ -n "${_startup_t0:-}" && -n "${_startup_t1:-}" ]]; then
      STARTUP_DUR_S=$((_startup_t1 - _startup_t0))
    fi
  }

  _startup_on_return() {
    EXPLAIN="${_startup_prev_explain:-false}"

    # Restore prior inventory index binding for other modules.
    if [[ -n "${_startup_prev_inventory_index_file:-}" ]]; then
      INVENTORY_INDEX_FILE="${_startup_prev_inventory_index_file}"
      export INVENTORY_INDEX_FILE
    else
      unset INVENTORY_INDEX_FILE 2>/dev/null || true
    fi

    _startup_finish_timing
  }
  trap _startup_on_return RETURN

  # Summary counters (exported via globals for mc-leaner.sh run summary)
  STARTUP_CHECKED=0
  STARTUP_FLAGGED=0
  STARTUP_UNKNOWN=0
  STARTUP_BOOT_FLAGGED=0
  STARTUP_LOGIN_FLAGGED=0
  STARTUP_IMPACT_HIGH=0
  STARTUP_SURFACE="launchd+loginitems"

  # Compatibility aliases for mc-leaner.sh summary naming.
  STARTUP_CHECKED_COUNT=0
  STARTUP_FLAGGED_COUNT=0
  STARTUP_UNKNOWN_OWNER_COUNT=0
  STARTUP_BOOT_FLAGGED_COUNT=0
  STARTUP_LOGIN_FLAGGED_COUNT=0
  STARTUP_SURFACE_BREAKDOWN="${STARTUP_SURFACE}"
  STARTUP_THRESHOLD_MODE="n/a"
  STARTUP_ESTIMATED_RISK="low"

  # Collect identifiers for flagged startup items (prefer label; fall back to plist path).
  declare -a STARTUP_FLAGGED_IDS=()
  STARTUP_FLAGGED_IDS_LIST=""

  if [[ "${mode}" == "clean" || "${apply}" == "true" ]]; then
    _startup_explain "${explain}" "Startup: clean/apply requested, but startup is inspection-only; running scan"
  fi

  _startup_explain "${explain}" "Startup: scanning launchd + login items"

  _startup_scan_launchd_dir "${explain}" "${HOME}/Library/LaunchAgents" "LaunchAgent"
  _startup_scan_launchd_dir "${explain}" "/Library/LaunchAgents" "LaunchAgent"

  _startup_scan_launchd_dir "${explain}" "/Library/LaunchDaemons" "LaunchDaemon"
  _startup_scan_launchd_dir "${explain}" "/System/Library/LaunchDaemons" "LaunchDaemon"

  _startup_scan_login_items "${explain}"

  # Ignore EPIPE when downstream closes early (e.g., `head -n`).
  STARTUP_FLAGGED_IDS_LIST=""
  if [[ ${#STARTUP_FLAGGED_IDS[@]} -gt 0 ]]; then
    STARTUP_FLAGGED_IDS_LIST="$({ printf '%s\n' "${STARTUP_FLAGGED_IDS[@]}"; } 2>/dev/null || true)"
    STARTUP_FLAGGED_IDS_LIST="${STARTUP_FLAGGED_IDS_LIST%$'\n'}"
  fi

  # Estimated risk (v2.2.0): conservative summary hinting.
  STARTUP_ESTIMATED_RISK="low"
  if [[ "${STARTUP_IMPACT_HIGH:-0}" -ge 3 || ( "${STARTUP_IMPACT_HIGH:-0}" -ge 1 && "${STARTUP_BOOT_FLAGGED:-0}" -ge 3 ) ]]; then
    STARTUP_ESTIMATED_RISK="high"
  elif [[ "${STARTUP_IMPACT_HIGH:-0}" -ge 1 || "${STARTUP_FLAGGED:-0}" -ge 10 ]]; then
    STARTUP_ESTIMATED_RISK="medium"
  fi

  # Sync compatibility aliases for mc-leaner.sh summary.
  STARTUP_CHECKED_COUNT="${STARTUP_CHECKED}"
  STARTUP_FLAGGED_COUNT="${STARTUP_FLAGGED}"
  STARTUP_UNKNOWN_OWNER_COUNT="${STARTUP_UNKNOWN}"
  STARTUP_BOOT_FLAGGED_COUNT="${STARTUP_BOOT_FLAGGED}"
  STARTUP_LOGIN_FLAGGED_COUNT="${STARTUP_LOGIN_FLAGGED}"
  STARTUP_SURFACE_BREAKDOWN="${STARTUP_SURFACE}"
  STARTUP_ESTIMATED_RISK="${STARTUP_ESTIMATED_RISK}"

  log "Startup: inspected ${STARTUP_CHECKED} item(s); flagged ${STARTUP_FLAGGED} (unknown owner ${STARTUP_UNKNOWN})"
}

# Compatibility: some runners may call `run_startup` (without the `_module` suffix).
run_startup() {
  run_startup_module "$@"
}

# End of module