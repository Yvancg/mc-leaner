#!/bin/bash
# mc-leaner: shared utilities
# Purpose: Provide small, reusable helpers for logging, command detection, and temporary file creation
# Safety: Pure helper functions; no file moves, no privilege escalation, no destructive operations
# NOTE: This library avoids setting shell-global strict mode.
# The entrypoint (mc-leaner.sh) is responsible for `set -euo pipefail`.

# ----------------------------
# Logging
# ----------------------------
# Purpose: Emit a stable timestamp for log lines.
# Safety: Logging only.
ts() {
  date +"%Y-%m-%d %H:%M:%S"
}

# Purpose: Emit a single log line with timestamp prefix.
# Safety: Logging only.
log() {
  printf "[%s] %s\n" "$(ts)" "$*"
}

# Compatibility aliases (modules and entrypoint may call these)
log_info()  { log "$@"; }
log_warn()  { log "$@"; }
log_error() { log "$@"; }

# Purpose: Log an error message and exit non-zero
# Usage: die "message" [exit_code]
die() {
  local msg="${1:-}"
  local code="${2:-1}"
  log_error "$msg"
  exit "$code"
}

# Purpose: Emit verbose reasoning only when --explain is enabled.
# Safety: Logging only.
explain_log() {
  if [ "${EXPLAIN:-false}" = "true" ]; then
    log "EXPLAIN: $*"
  fi
}

# ----------------------------
# Environment checks
# ----------------------------
is_cmd() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------
# Temporary files
# ----------------------------
tmpfile() {
  # Purpose: create a unique temp file path compatible with macOS Bash 3.2
  mktemp "/tmp/mc-leaner.XXXXXX"
}

# ----------------------------
# Background services (v2.3.0 contract)
# ----------------------------
# Purpose: provide a stable, grep-friendly record format for persistent services.
# Safety: logging only; does not inspect network traffic, sockets, or runtime state.
# Notes: network_facing is locked to false for now (heuristics added later).

PRIVACY_TOTAL_SERVICES=0
PRIVACY_UNKNOWN_SERVICES=0
PRIVACY_NETWORK_FACING_SERVICES=0

# Newline-delimited SERVICE? records for cross-module correlation (v2.3.0 step 3).
# Format: scope=... | persistence=... | owner=... | label=...
SERVICE_RECORDS_LIST=""


# Newline-sentinel for Bash 3.2-safe dedupe by label.
SERVICE_LABELS_SEEN=$'\n'

# ----------------------------
# Inventory-backed label-prefix attribution
# ----------------------------
# Purpose: attribute an owner from a launchd label by matching installed bundle-id prefixes in the inventory index.
# Safety: inspection-only; reads inventory TSV only.

inventory_owner_by_label_prefix() {
  # Contract:
  #   inventory_owner_by_label_prefix <label> [inventory_index_file]
  # Output (newline terminated on success):
  #   <owner>\t<how>\t<confidence>
  # where:
  #   how=inventory-label-prefix-match
  #   confidence=medium when prefix has >=3 components, else low
  # Returns non-zero and prints nothing on no match.

  local label="${1:-}"
  local inventory_index_file="${2:-${INVENTORY_INDEX_FILE:-}}"

  [[ -n "$label" ]] || return 1
  [[ -n "$inventory_index_file" && -f "$inventory_index_file" ]] || return 1

  # Only attempt on reverse-DNS style labels.
  [[ "$label" == *.*.* ]] || return 1

  local parts_count="0"
  parts_count="$(awk -F'.' '{print NF+0}' <<<"$label" 2>/dev/null || echo 0)"
  [[ "$parts_count" -ge 2 ]] || return 1

  local i prefix hit
  for ((i=parts_count-1; i>=2; i--)); do
    prefix="$(cut -d'.' -f1-"$i" <<<"$label" 2>/dev/null || true)"
    [[ -n "$prefix" ]] || continue

    # Match inventory keys that look like bundle ids and are not path:/brew: keys.
    hit="$(awk -F'\t' -v p="$prefix" '
      $1 !~ /^path:/ && $1 !~ /^brew:/ && $1 ~ /\./ && index($1,p)==1 {print $2; exit}
    ' "$inventory_index_file" 2>/dev/null)" || true

    if [[ -n "$hit" ]]; then
      if [[ "$i" -ge 3 ]]; then
        printf '%s\tinventory-label-prefix-match\tmedium\n' "$hit"
      else
        printf '%s\tinventory-label-prefix-match\tlow\n' "$hit"
      fi
      return 0
    fi
  done

  return 1
}

# ----------------------------
# Network-facing heuristics (v2.3.0, static)
# ----------------------------
# Purpose: classify likely network-facing background services using static signals.
# Safety: no traffic inspection, no socket enumeration, no runtime probing.
# Policy: default false; only mark true on explicit matches.

# Rule IDs (stable):
# - NF_VPN_OWNER
# - NF_CLOUD_STORAGE_OWNER
# - NF_SYNC_CLIENT_OWNER
# - NF_TELEMETRY_UPDATE_OWNER
# - NF_REMOTE_ACCESS_OWNER
# - NF_LABEL_ALLOWLIST

_service_normalize() {
  # Purpose: normalize for conservative matching (lowercase, strip spaces/punct).
  echo "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'
}

_service_owner_in_list() {
  # Usage: _service_owner_in_list <owner> <list...>
  local owner_raw="${1:-}"
  shift || true

  local owner_norm
  owner_norm="$(_service_normalize "$owner_raw")"
  [[ -n "$owner_norm" ]] || return 1

  local x
  for x in "$@"; do
    [[ "$owner_norm" == "$(_service_normalize "$x")" ]] && return 0
  done
  return 1
}

_service_label_in_list() {
  # Usage: _service_label_in_list <label> <list...>
  local label="${1:-}"
  shift || true
  [[ -n "$label" ]] || return 1

  local x
  for x in "$@"; do
    [[ "$label" == "$x" ]] && return 0
  done
  return 1
}

# Conservative vendor lists (explicit only). Update intentionally.
NF_VPN_OWNERS=(
  "Tailscale"
  "NordVPN"
  "ExpressVPN"
  "ProtonVPN"
  "Surfshark"
  "Mullvad"
  "Cloudflare WARP"
)

NF_CLOUD_STORAGE_OWNERS=(
  "Dropbox"
  "Google Drive"
  "OneDrive"
  "Box"
  "MEGA"
  "Nextcloud"
)

NF_SYNC_CLIENT_OWNERS=(
  "Mozilla"
)

NF_TELEMETRY_UPDATE_OWNERS=(
  "Adobe"
  "Dropbox"
  "Zoom"
  "Google Keystone"
)

NF_REMOTE_ACCESS_OWNERS=(
  "TeamViewer"
  "AnyDesk"
  "LogMeIn"
  "Splashtop"
  "Chrome Remote Desktop"
)

# Exact label allowlist for known network-facing services.
# Intentionally empty; fallback only.
NF_LABEL_ALLOWLIST=(
)

service_network_facing_classify() {
  # Contract:
  #   service_network_facing_classify <owner> <label>
  # Output (tab-delimited):
  #   <true|false>\t<rule_id|->\t<reason|->
  #
  # Owner-first: if we have a known owner, prefer explicit owner-class rules.
  local owner="${1:-Unknown}"
  local label="${2:-}"

  # Owner-first: if we have a known owner, prefer explicit owner-class rules.
  if [[ -n "$owner" && "$owner" != "Unknown" ]]; then
    if _service_owner_in_list "$owner" "${NF_VPN_OWNERS[@]:-}"; then
      printf 'true\tNF_VPN_OWNER\tvpn_vendor_match'
      return 0
    fi

    if _service_owner_in_list "$owner" "${NF_CLOUD_STORAGE_OWNERS[@]:-}"; then
      printf 'true\tNF_CLOUD_STORAGE_OWNER\tcloud_storage_vendor_match'
      return 0
    fi

    if _service_owner_in_list "$owner" "${NF_SYNC_CLIENT_OWNERS[@]:-}"; then
      printf 'true\tNF_SYNC_CLIENT_OWNER\tsync_client_vendor_match'
      return 0
    fi

    if _service_owner_in_list "$owner" "${NF_TELEMETRY_UPDATE_OWNERS[@]:-}"; then
      printf 'true\tNF_TELEMETRY_UPDATE_OWNER\ttelemetry_update_vendor_match'
      return 0
    fi

    if _service_owner_in_list "$owner" "${NF_REMOTE_ACCESS_OWNERS[@]:-}"; then
      printf 'true\tNF_REMOTE_ACCESS_OWNER\tremote_access_vendor_match'
      return 0
    fi

    # Known owner but no explicit class match.
    printf 'false\t-\t-'
    return 0
  fi

  # Owner unknown: allow explicit label allowlist as the only path to true.
  if _service_label_in_list "$label" "${NF_LABEL_ALLOWLIST[@]:-}"; then
    printf 'true\tNF_LABEL_ALLOWLIST\tlabel_allowlist_match'
    return 0
  fi

  printf 'false\t-\t-'
}

privacy_reset_counters() {
  # Purpose: reset per-run privacy counters.
  # Safety: state only.
  PRIVACY_TOTAL_SERVICES=0
  PRIVACY_UNKNOWN_SERVICES=0
  PRIVACY_NETWORK_FACING_SERVICES=0
  SERVICE_RECORDS_LIST=""
  SERVICE_LABELS_SEEN=$'\n'
}

service_emit_record() {
  # Contract:
  #   service_emit_record <scope> <persistence> <owner> <network_facing> <label>
  #
  # Output format (single line):
  #   SERVICE? scope=<system|user> | persistence=<boot|login|on-demand> | owner=<OwnerName|Unknown> | network_facing=<true|false> | label=<...>
  #
  # Safety: logging only.
  local scope="${1:-}"
  local persistence="${2:-}"
  local owner="${3:-Unknown}"
  local network_facing="${4:-}"
  local label="${5:-}"

  # Default: conservative false unless explicitly matched by static heuristics.
  [[ -n "$network_facing" ]] || network_facing="false"

  # Fail-closed: do not emit malformed records.
  if [[ -z "$scope" || -z "$persistence" || -z "$label" ]]; then
    explain_log "service_emit_record: skip (missing fields) scope='$scope' persistence='$persistence' label='$label'"
    return 0
  fi

  # Normalize label for stable dedupe.
  label="$(printf '%s' "$label" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$label" ]] || return 0

  # Dedupe by label (exact match). Do not double-count or re-emit.
  if [[ "${SERVICE_LABELS_SEEN}" == *$'\n'"${label}"$'\n'* ]]; then
    explain_log "service_emit_record: skip (duplicate label) label='${label}'"
    return 0
  fi
  SERVICE_LABELS_SEEN+="${label}"$'\n'

  PRIVACY_TOTAL_SERVICES=$((PRIVACY_TOTAL_SERVICES + 1))
  if [[ "$owner" == "Unknown" || -z "$owner" ]]; then
    PRIVACY_UNKNOWN_SERVICES=$((PRIVACY_UNKNOWN_SERVICES + 1))
    owner="Unknown"
  fi

  # Static network-facing classification (conservative; explicit matches only).
  local nf_out="" nf="false" nf_rule="-" nf_reason="-"
  nf_out="$(service_network_facing_classify "$owner" "$label")"
  nf="${nf_out%%$'\t'*}"
  nf_rule="${nf_out#*$'\t'}"; nf_rule="${nf_rule%%$'\t'*}"
  nf_reason="${nf_out##*$'\t'}"

  network_facing="$nf"
  if [[ "$network_facing" == "true" ]]; then
    PRIVACY_NETWORK_FACING_SERVICES=$((PRIVACY_NETWORK_FACING_SERVICES + 1))
    explain_log "network_facing=true because ${nf_rule}: owner=${owner} reason=${nf_reason} label=${label}"
  fi

  log "SERVICE? scope=${scope} | persistence=${persistence} | owner=${owner} | network_facing=${network_facing} | label=${label}"

  # Keep a structured copy for correlation (logging remains the source of truth).
  SERVICE_RECORDS_LIST+="scope=${scope} | persistence=${persistence} | owner=${owner} | label=${label}"$'\n'
}

privacy_summary_line() {
  # Purpose: emit a stable, parseable privacy summary line for end-of-run summary.
  # Safety: logging only.
  printf 'privacy: total_services=%s unknown_services=%s network_facing=%s' \
    "${PRIVACY_TOTAL_SERVICES}" \
    "${PRIVACY_UNKNOWN_SERVICES}" \
    "${PRIVACY_NETWORK_FACING_SERVICES}"
}

# ----------------------------
# Run summary (collector)
# ----------------------------
# Purpose: allow modules to register end-of-run summary lines; printed once by the entrypoint
# Safety: logging only

# Bash 3.2 compatibility: initialize arrays defensively under set -u
#
# Legacy/freeform summary lines (kept for backward compatibility)
declare -a SUMMARY_LINES
SUMMARY_LINES=()

# Structured summary lines (recommended)
declare -a SUMMARY_MODULE_LINES
declare -a SUMMARY_ACTION_LINES
declare -a SUMMARY_INFO_LINES
SUMMARY_MODULE_LINES=()
SUMMARY_ACTION_LINES=()
SUMMARY_INFO_LINES=()

summary__ensure_arrays() {
  # Purpose: ensure summary arrays exist even if unset by a caller
  # Safety: logging only
  # Notes: required for Bash 3.2 + `set -u` (avoids unbound variable errors)

  if ! declare -p SUMMARY_LINES >/dev/null 2>&1; then
    declare -a SUMMARY_LINES
    SUMMARY_LINES=()
  fi

  if ! declare -p SUMMARY_MODULE_LINES >/dev/null 2>&1; then
    declare -a SUMMARY_MODULE_LINES
    SUMMARY_MODULE_LINES=()
  fi

  if ! declare -p SUMMARY_ACTION_LINES >/dev/null 2>&1; then
    declare -a SUMMARY_ACTION_LINES
    SUMMARY_ACTION_LINES=()
  fi

  if ! declare -p SUMMARY_INFO_LINES >/dev/null 2>&1; then
    declare -a SUMMARY_INFO_LINES
    SUMMARY_INFO_LINES=()
  fi
}

summary_add() {
  # Usage (legacy): summary_add "Module: flagged 2; moved 1; failures 0"
  # Purpose: allow older modules to register a human-readable summary line
  # Safety: logging only
  summary__ensure_arrays
  SUMMARY_LINES+=("$*")
}

summary_add_module_line() {
  # Usage: summary_add_module_line "caches scanned_dirs=88 total_mb=599 | flagged=1 | moved=no"
  # Purpose: register a single, parseable module line for the consolidated summary
  # Safety: logging only
  summary__ensure_arrays
  SUMMARY_MODULE_LINES+=("$*")
}

summary_add_action() {
  # Usage: summary_add_action "caches: 1 item(s) above threshold (review before moving)"
  # Purpose: register an action-required line (things that likely need user attention)
  # Safety: logging only
  summary__ensure_arrays
  SUMMARY_ACTION_LINES+=("$*")
}

summary_add_info() {
  # Usage: summary_add_info "intel: report written to /Users/yvan/Desktop/intel_binaries.txt"
  # Purpose: register an informational line (non-actionable outputs)
  # Safety: logging only
  summary__ensure_arrays
  SUMMARY_INFO_LINES+=("$*")
}

summary_print() {
  # Purpose: print consolidated summary at end of run

  summary__ensure_arrays

  local module_count=${#SUMMARY_MODULE_LINES[@]}
  local legacy_count=${#SUMMARY_LINES[@]}
  local action_count=${#SUMMARY_ACTION_LINES[@]}
  local info_count=${#SUMMARY_INFO_LINES[@]}

  if [ "$module_count" -eq 0 ] && [ "$legacy_count" -eq 0 ] && [ "$action_count" -eq 0 ] && [ "$info_count" -eq 0 ]; then
    return 0
  fi

  log "RUN SUMMARY:"

  if [ "${PRIVACY_TOTAL_SERVICES:-0}" -gt 0 ]; then
    log "  - $(privacy_summary_line)"
  fi
  if [ "${PRIVACY_NETWORK_FACING_SERVICES:-0}" -gt 0 ] && [ "${PRIVACY_UNKNOWN_SERVICES:-0}" -gt 0 ]; then
    log "  - risk: background_services_with_network_access"
  fi

  local line

  if [ "$module_count" -gt 0 ]; then
    for line in "${SUMMARY_MODULE_LINES[@]}"; do
      log "  - $line"
    done
  fi

  # Print legacy/freeform lines after structured lines (if any)
  if [ "$legacy_count" -gt 0 ]; then
    for line in "${SUMMARY_LINES[@]}"; do
      log "  - $line"
    done
  fi

  if [ "$action_count" -gt 0 ]; then
    log ""
    log "ACTION REQUIRED:"
    for line in "${SUMMARY_ACTION_LINES[@]}"; do
      log "  - $line"
    done
  fi

  if [ "$info_count" -gt 0 ]; then
    log ""
    log "INFO ONLY:"
    for line in "${SUMMARY_INFO_LINES[@]}"; do
      log "  - $line"
    done
  fi
}

# Note: privacy counters are initialized by the entrypoint (mc-leaner.sh) once per run.

# End of library
