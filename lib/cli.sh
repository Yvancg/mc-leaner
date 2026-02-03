#!/bin/bash
# mc-leaner: CLI parsing utilities
# Purpose: Define supported flags, defaults, and help output for the mc-leaner entry point
# Safety: Enforces explicit opt-in for any cleanup action via `--apply`; defaults to dry-run mode

# ----------------------------
# Defaults
# ----------------------------

MODE="scan"
APPLY="false"
APPLY_SET="false"
BACKUP_DIR=""
EXPLAIN="false"
STARTUP_INCLUDE_SYSTEM="false"
CONFIG_FILE="$HOME/.mcleanerrc"
THRESHOLD_CACHES_MB="200"
THRESHOLD_LOGS_MB="50"
THRESHOLD_LEFTOVERS_MB="50"
THRESHOLD_DISK_MB="200"
THRESHOLD_KV=""
JSON_OUTPUT="false"
JSON_STDOUT="false"
JSON_FILE=""
EXPORT_FILE=""
LIST_BACKUPS="false"
RESTORE_BACKUP_DIR=""
PROGRESS="false"
THRESHOLD_CACHES_MB_SET="false"
THRESHOLD_LOGS_MB_SET="false"
THRESHOLD_LEFTOVERS_MB_SET="false"
THRESHOLD_DISK_MB_SET="false"

# Supported modes are declared once to avoid drift between help text and validation.
SUPPORTED_MODES=(
  scan
  clean
  report
  inventory-only
  launchd-only
  startup-only
  bins-only
  caches-only
  logs-only
  brew-only
  leftovers-only
  permissions-only
  disk-only
)

# ----------------------------
# Help Text
# ----------------------------

usage() {
  cat <<EOF
mc-leaner — inspection-first system hygiene with explicit run summaries

Usage:
  bash mc-leaner.sh [--mode <mode>] [--apply] [--backup-dir <path>] [--explain] [--startup-system] [--json] [--json-file <path>] [--export <path>]
                   [--list-backups] [--restore-backup <path>]
                   [--progress]
                   [--threshold <list>] [--threshold-caches <mb>] [--threshold-logs <mb>]
                   [--threshold-leftovers <mb>] [--threshold-disk <mb>]

Modes:
  $(printf '%s' "${SUPPORTED_MODES[*]}" | tr ' ' '|')

Defaults:
  --mode scan     (inspection-only; no moves)
  --apply         required for any move

Notes:
  - All inspection modes list every flagged item in the end-of-run summary
  - Counts are always paired with explicit identifiers
  - Config file: ~/.mcleanerrc (key=value)

Options:
  --explain       Show why items are skipped or flagged (verbose; allowed in all modes)
  --startup-system
                  Include system launchd items in startup scan (default: user-only)
  --json          Emit a JSON summary to stdout (captures machine records)
  --json-file     Write JSON summary to a file (separate from --export)
  --export        Write a full report to a file (human logs + machine records)
  --list-backups  List backup folders created on this machine
  --restore-backup
                  Restore items from a backup folder (uses manifest; prompts per item)
  --progress      Emit a simple progress indicator per module
  --threshold     Comma list of thresholds (MB). Example: caches=300,logs=100,leftovers=75,disk=500
  --threshold-caches     Override cache size threshold (MB; default: 200)
  --threshold-logs       Override log size threshold (MB; default: 50)
  --threshold-leftovers  Override leftovers size threshold (MB; default: 50)
  --threshold-disk       Override disk consumer threshold (MB; default: 200)

Examples:
  bash mc-leaner.sh
  bash mc-leaner.sh --mode clean --apply
  bash mc-leaner.sh --mode report
  bash mc-leaner.sh --mode inventory-only
  bash mc-leaner.sh --mode startup-only
  bash mc-leaner.sh --mode disk-only
  bash mc-leaner.sh --mode caches-only
  bash mc-leaner.sh --mode logs-only
  bash mc-leaner.sh --mode brew-only
  bash mc-leaner.sh --mode leftovers-only
  bash mc-leaner.sh --mode permissions-only
  bash mc-leaner.sh --mode scan --threshold caches=300,logs=100
  bash mc-leaner.sh --mode caches-only --threshold-caches 500
  bash mc-leaner.sh --mode scan --json
  bash mc-leaner.sh --mode scan --json-file ~/Desktop/mc-leaner.json
  bash mc-leaner.sh --mode scan --export ~/Desktop/mc-leaner_report.txt
  bash mc-leaner.sh --list-backups
  bash mc-leaner.sh --restore-backup ~/Desktop/McLeaner_Backups_20260201_101010
  bash mc-leaner.sh --mode scan --progress
EOF
}

# ----------------------------
# Argument Parsing
# ----------------------------

parse_args() {
  # Fail-closed CLI parsing: accept only known flags to avoid unintended behavior
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) MODE="${2:-}"; shift 2 ;;
      --apply) APPLY="true"; APPLY_SET="true"; shift ;;
      --backup-dir) BACKUP_DIR="${2:-}"; shift 2 ;;
      --explain) EXPLAIN="true"; shift ;;
      --startup-system) STARTUP_INCLUDE_SYSTEM="true"; shift ;;
      --json) JSON_STDOUT="true"; JSON_OUTPUT="true"; shift ;;
      --json-file) JSON_FILE="${2:-}"; JSON_OUTPUT="true"; shift 2 ;;
      --export) EXPORT_FILE="${2:-}"; shift 2 ;;
      --list-backups) LIST_BACKUPS="true"; shift ;;
      --restore-backup) RESTORE_BACKUP_DIR="${2:-}"; shift 2 ;;
      --progress) PROGRESS="true"; shift ;;
      --threshold) THRESHOLD_KV="${2:-}"; shift 2 ;;
      --threshold-caches) THRESHOLD_CACHES_MB="${2:-}"; THRESHOLD_CACHES_MB_SET="true"; shift 2 ;;
      --threshold-logs) THRESHOLD_LOGS_MB="${2:-}"; THRESHOLD_LOGS_MB_SET="true"; shift 2 ;;
      --threshold-leftovers) THRESHOLD_LEFTOVERS_MB="${2:-}"; THRESHOLD_LEFTOVERS_MB_SET="true"; shift 2 ;;
      --threshold-disk) THRESHOLD_DISK_MB="${2:-}"; THRESHOLD_DISK_MB_SET="true"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      # SAFETY: reject unknown flags to prevent accidental mode or apply changes
      *) echo "Unknown arg: $1"; usage; exit 1 ;;
    esac
  done

  # SAFETY: validate mode against the declared supported list (prevents drift and typos)
  validate_mode

  if [[ "${APPLY}" == "true" && "${APPLY_SET}" != "true" ]]; then
    _cli_log "Config: apply ignored unless --apply flag is provided"
    APPLY="false"
  fi

  if [[ -n "${JSON_FILE:-}" ]]; then
    JSON_OUTPUT="true"
  fi

  # Thresholds: validate and apply list overrides (if any)
  apply_threshold_overrides
}

_cli_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$@"
  else
    echo "$@" >&2
  fi
}

_cli_trim() {
  local s="$1"
  echo "$s" | awk '{$1=$1;print}'
}

_cli_strip_quotes() {
  local s="$1"
  if [[ "$s" =~ ^".*"$ ]]; then
    s="${s#\"}"
    s="${s%\"}"
  elif [[ "$s" =~ ^'.*'$ ]]; then
    s="${s#\'}"
    s="${s%\'}"
  fi
  printf '%s' "$s"
}

_cli_bool_parse() {
  local v="$1"
  case "$v" in
    1|true|TRUE|yes|YES|y|Y) echo "true"; return 0 ;;
    0|false|FALSE|no|NO|n|N) echo "false"; return 0 ;;
    *) return 1 ;;
  esac
}

load_config_file() {
  local cfg="${CONFIG_FILE:-$HOME/.mcleanerrc}"
  [[ -f "$cfg" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(_cli_trim "$line")"
    [[ -n "$line" ]] || continue
    if [[ "$line" != *=* ]]; then
      _cli_log "Config: invalid line (expected key=value): $line"
      continue
    fi
    key="${line%%=*}"
    value="${line#*=}"
    key="$(_cli_trim "$key")"
    value="$(_cli_trim "$value")"
    value="$(_cli_strip_quotes "$value")"

    case "$key" in
      mode|MODE)
        MODE="$value"
        ;;
      apply|APPLY)
        if value="$(_cli_bool_parse "$value")"; then
          APPLY="$value"
        else
          _cli_log "Config: invalid apply value: $value"
        fi
        ;;
      backup_dir|backup-dir|BACKUP_DIR)
        BACKUP_DIR="$value"
        ;;
      explain|EXPLAIN)
        if value="$(_cli_bool_parse "$value")"; then
          EXPLAIN="$value"
        else
          _cli_log "Config: invalid explain value: $value"
        fi
        ;;
      startup_system|startup-system|STARTUP_INCLUDE_SYSTEM)
        if value="$(_cli_bool_parse "$value")"; then
          STARTUP_INCLUDE_SYSTEM="$value"
        else
          _cli_log "Config: invalid startup_system value: $value"
        fi
        ;;
      json|JSON_OUTPUT)
        if value="$(_cli_bool_parse "$value")"; then
          JSON_OUTPUT="$value"
        else
          _cli_log "Config: invalid json value: $value"
        fi
        ;;
      json_file|json-file|JSON_FILE)
        JSON_FILE="$value"
        JSON_OUTPUT="true"
        ;;
      export|EXPORT_FILE)
        EXPORT_FILE="$value"
        ;;
      list_backups|list-backups|LIST_BACKUPS)
        if value="$(_cli_bool_parse "$value")"; then
          LIST_BACKUPS="$value"
        else
          _cli_log "Config: invalid list_backups value: $value"
        fi
        ;;
      restore_backup|restore-backup|RESTORE_BACKUP_DIR)
        RESTORE_BACKUP_DIR="$value"
        ;;
      progress|PROGRESS)
        if value="$(_cli_bool_parse "$value")"; then
          PROGRESS="$value"
        else
          _cli_log "Config: invalid progress value: $value"
        fi
        ;;
      threshold|thresholds|THRESHOLD_KV)
        THRESHOLD_KV="$value"
        ;;
      threshold_caches|threshold-caches|THRESHOLD_CACHES_MB)
        THRESHOLD_CACHES_MB="$value"
        ;;
      threshold_logs|threshold-logs|THRESHOLD_LOGS_MB)
        THRESHOLD_LOGS_MB="$value"
        ;;
      threshold_leftovers|threshold-leftovers|THRESHOLD_LEFTOVERS_MB)
        THRESHOLD_LEFTOVERS_MB="$value"
        ;;
      threshold_disk|threshold-disk|THRESHOLD_DISK_MB)
        THRESHOLD_DISK_MB="$value"
        ;;
      *)
        _cli_log "Config: unknown key ignored: $key"
        ;;
    esac
  done < "$cfg"
}

apply_threshold_overrides() {
  local caches_cli=""
  local logs_cli=""
  local leftovers_cli=""
  local disk_cli=""

  if [[ "${THRESHOLD_CACHES_MB_SET:-false}" == "true" ]]; then
    caches_cli="${THRESHOLD_CACHES_MB}"
  fi
  if [[ "${THRESHOLD_LOGS_MB_SET:-false}" == "true" ]]; then
    logs_cli="${THRESHOLD_LOGS_MB}"
  fi
  if [[ "${THRESHOLD_LEFTOVERS_MB_SET:-false}" == "true" ]]; then
    leftovers_cli="${THRESHOLD_LEFTOVERS_MB}"
  fi
  if [[ "${THRESHOLD_DISK_MB_SET:-false}" == "true" ]]; then
    disk_cli="${THRESHOLD_DISK_MB}"
  fi

  _threshold_validate_int() {
    local name="$1"
    local val="$2"
    if [[ -z "$val" || ! "$val" =~ ^[0-9]+$ ]]; then
      echo "Invalid ${name} threshold: ${val} (expected integer MB)"
      usage
      exit 1
    fi
  }

  # Apply key=value list first, then allow explicit flags to override later.
  if [[ -n "${THRESHOLD_KV:-}" ]]; then
    local pair
    local key
    local value
    local -a pairs
    IFS=',' read -r -a pairs <<< "${THRESHOLD_KV}"
    for pair in "${pairs[@]:-}"; do
      pair="$(echo "$pair" | awk '{$1=$1;print}')"
      [[ -n "$pair" ]] || continue
      if [[ "$pair" != *"="* ]]; then
        echo "Invalid --threshold entry: $pair (expected key=value)"
        usage
        exit 1
      fi
      key="${pair%%=*}"
      value="${pair#*=}"
      key="$(echo "$key" | awk '{$1=$1;print}')"
      value="$(echo "$value" | awk '{$1=$1;print}')"
      case "$key" in
        caches)
          _threshold_validate_int "caches" "$value"
          THRESHOLD_CACHES_MB="$value"
          ;;
        logs)
          _threshold_validate_int "logs" "$value"
          THRESHOLD_LOGS_MB="$value"
          ;;
        leftovers)
          _threshold_validate_int "leftovers" "$value"
          THRESHOLD_LEFTOVERS_MB="$value"
          ;;
        disk)
          _threshold_validate_int "disk" "$value"
          THRESHOLD_DISK_MB="$value"
          ;;
        *)
          echo "Invalid --threshold key: $key (valid: caches, logs, leftovers, disk)"
          usage
          exit 1
          ;;
      esac
    done
  fi

  # Re-apply explicit CLI flags after list parsing.
  if [[ -n "${caches_cli}" ]]; then
    THRESHOLD_CACHES_MB="${caches_cli}"
  fi
  if [[ -n "${logs_cli}" ]]; then
    THRESHOLD_LOGS_MB="${logs_cli}"
  fi
  if [[ -n "${leftovers_cli}" ]]; then
    THRESHOLD_LEFTOVERS_MB="${leftovers_cli}"
  fi
  if [[ -n "${disk_cli}" ]]; then
    THRESHOLD_DISK_MB="${disk_cli}"
  fi

  _threshold_validate_int "caches" "${THRESHOLD_CACHES_MB}"
  _threshold_validate_int "logs" "${THRESHOLD_LOGS_MB}"
  _threshold_validate_int "leftovers" "${THRESHOLD_LEFTOVERS_MB}"
  _threshold_validate_int "disk" "${THRESHOLD_DISK_MB}"
}

validate_mode() {
  # Validate --mode strictly against SUPPORTED_MODES (single source of truth)
  local m
  for m in "${SUPPORTED_MODES[@]}"; do
    if [[ "$MODE" == "$m" ]]; then
      return 0
    fi
  done

  echo "Invalid --mode: $MODE"
  usage
  exit 1
}

# End of library
