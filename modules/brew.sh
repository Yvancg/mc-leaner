#!/bin/bash
# shellcheck shell=bash
# mc-leaner: brew module (inspection-first)
# Purpose: provide visibility into Homebrew state and disk usage
# Safety: read-only; does NOT run brew cleanup/uninstall/upgrade; no filesystem writes
# Notes: best-effort parsing; macOS default bash 3.2 compatible

# NOTE: Modules run with strict mode for deterministic failures and auditability.
set -euo pipefail

# Suppress SIGPIPE noise and cascading stdout corruption when output is piped to a consumer that exits early
# (e.g., `head -n`, `rg -m`). Safety: logging ergonomics only; does not change inspection logic/results.
trap '' PIPE

# ----------------------------
# Summary Buckets
# ----------------------------
# Purpose: Store end-of-run buckets for a stable summary.
# Safety: In-memory only; no filesystem writes.
BREW_LEAVES_LIST=()
BREW_OUTDATED_UNPINNED=()
BREW_OUTDATED_PINNED=()
BREW_TOP_SIZES=()          # entries like: "name|mb|versions"
BREW_CACHE_LINES=()        # human-readable cache summary lines
BREW_FLAGGED_ITEMS=()      # actionable review items (end-of-run)

# ----------------------------
# Module-scoped state
# ----------------------------
BREW_EXPLAIN="false"
BREW_TMPFILES=()

# Stable exported summary fields (set in run_brew_module)
BREW_FLAGGED_COUNT="0"
BREW_FLAGGED_IDS_LIST=""
BREW_DUR_S=0
BREW_FORMULAE_COUNT="0"
BREW_CASKS_COUNT="0"
BREW_OUTDATED_UNPINNED_COUNT="0"
BREW_OUTDATED_PINNED_COUNT="0"
BREW_LEAVES_COUNT="0"

# ----------------------------
# Defensive Checks
# ----------------------------
if ! type explain_log >/dev/null 2>&1; then
  explain_log() {
    # Purpose: Best-effort verbose logging when --explain is enabled.
    # Safety: Logging only.
    if [[ "${BREW_EXPLAIN:-false}" == "true" ]]; then
      log "$@"
    fi
  }
fi

# ----------------------------
# Helpers
# ----------------------------

_brew_tmpfile() {
  # Purpose: Create a temp file path for this module only.
  # Safety: Creates an empty temp file.
  # Rationale: Do not call shared tmpfile() in command substitution because it may log to stdout.
  local p
  p="$(mktemp -t mc-leaner_brew.XXXXXX 2>/dev/null || true)"
  [[ -n "${p:-}" ]] || return 1

  # Register for cleanup (safe under set -u)
  BREW_TMPFILES+=("${p}")

  printf '%s' "${p}"
}

_brew_array_len() {
  # Purpose: safe array length under `set -u` (returns 0 if unset)
  # Inputs: variable name
  local name="$1"

  # `declare -a foo` (without assignment) makes `declare -p foo` succeed even though
  # expanding `${foo[@]}` still errors under `set -u`. So we must check "is set" too.
  if declare -p "$name" >/dev/null 2>&1; then
    if eval '[[ ${'"$name"'[@]+x} ]]'; then
      eval "printf '%s\n' \${#${name}[@]}"
    else
      printf '0\n'
    fi
  else
    printf '0\n'
  fi
}


_brew_exists() {
  # Purpose: check whether Homebrew is installed
  command -v brew >/dev/null 2>&1
}

_brew_prefix() {
  # Purpose: return brew prefix (best-effort)
  # Safety: read-only
  brew --prefix 2>/dev/null || printf ''
}

_brew_kb_to_mb() {
  # Purpose: convert KB to MB (integer)
  # Safety: must be robust if caller passes non-numeric text (e.g., contaminated stdout).
  local kb_raw="${1:-0}"
  local kb="0"
  # Strip whitespace
  kb_raw="$(printf '%s' "${kb_raw}" | tr -d '[:space:]' 2>/dev/null || true)"
  # Accept only digits; fail closed to 0.
  if [[ -n "${kb_raw}" && "${kb_raw}" =~ ^[0-9]+$ ]]; then
    kb="${kb_raw}"
  else
    kb="0"
  fi

  printf '%s\n' $((kb / 1024))
}

_brew_dir_mb() {
  # Purpose: return directory size in MB (integer)
  # Notes: du -sk is stable across macOS
  # Safety: tolerate non-numeric outputs (treat as 0).
  local p="$1"
  local kb="0"
  local du_out=""

  du_out="$(du -sk "$p" 2>/dev/null | awk '{print $1}' 2>/dev/null || true)"
  du_out="$(printf '%s' "${du_out}" | tr -d '[:space:]' 2>/dev/null || true)"

  if [[ -n "${du_out}" && "${du_out}" =~ ^[0-9]+$ ]]; then
    kb="${du_out}"
  else
    kb="0"
  fi

  _brew_kb_to_mb "${kb}"
}


_brew_sorted_unique_lines() {
  # Purpose: normalize text list (sorted unique)
  # Usage: echo "$text" | _brew_sorted_unique_lines
  sort | awk 'NF' | uniq
}

_brew_display_path() {
  # Purpose: display a path without leaking full filesystem paths.
  # Behavior:
  #   - explain=true: show basename only, prefixed with ".../" (never full path)
  #   - explain=false: print "redacted"
  local p="${1:-}"

  if [[ "${BREW_EXPLAIN:-false}" == "true" ]]; then
    local b=""
    b="$(basename "${p}" 2>/dev/null || printf '%s' '')"
    if [[ -n "${b}" ]]; then
      printf '%s' ".../${b}"
    else
      printf '%s' ".../<path>"
    fi
    return 0
  fi

  printf '%s' 'redacted'
}

_brew_list_formulae() {
  # Purpose: list installed formulae
  # Inventory integration: if inventory already collected brew formulae, reuse it to reduce brew calls.
  # Supported env vars (set by inventory/orchestrator):
  #   - INVENTORY_READY=true
  #   - INVENTORY_BREW_FORMULAE_FILE=/path/to/file (newline-delimited)
  #   - INVENTORY_BREW_FORMULAE (newline-delimited)
  if [[ "${INVENTORY_READY:-false}" == "true" ]]; then
    if [[ -n "${INVENTORY_BREW_FORMULAE_FILE:-}" && -f "${INVENTORY_BREW_FORMULAE_FILE}" ]]; then
      cat "${INVENTORY_BREW_FORMULAE_FILE}" 2>/dev/null || true
      return 0
    fi
    if [[ -n "${INVENTORY_BREW_FORMULAE:-}" ]]; then
      printf "%s\n" "${INVENTORY_BREW_FORMULAE}" | awk 'NF'
      return 0
    fi
  fi

  brew list --formula 2>/dev/null || true
}

_brew_list_casks() {
  # Purpose: list installed casks
  # Inventory integration: if inventory already collected brew casks, reuse it to reduce brew calls.
  # Supported env vars (set by inventory/orchestrator):
  #   - INVENTORY_READY=true
  #   - INVENTORY_BREW_CASKS_FILE=/path/to/file (newline-delimited)
  #   - INVENTORY_BREW_CASKS (newline-delimited)
  if [[ "${INVENTORY_READY:-false}" == "true" ]]; then
    if [[ -n "${INVENTORY_BREW_CASKS_FILE:-}" && -f "${INVENTORY_BREW_CASKS_FILE}" ]]; then
      cat "${INVENTORY_BREW_CASKS_FILE}" 2>/dev/null || true
      return 0
    fi
    if [[ -n "${INVENTORY_BREW_CASKS:-}" ]]; then
      printf "%s\n" "${INVENTORY_BREW_CASKS}" | awk 'NF'
      return 0
    fi
  fi

  brew list --cask 2>/dev/null || true
}

_brew_leaves() {
  # Purpose: list leaf formulae (not depended on by other formulae)
  brew leaves 2>/dev/null || true
}

_brew_list_pinned_formulae() {
  # Purpose: list pinned formulae (excluded from brew upgrade)
  brew list --pinned 2>/dev/null || true
}

_brew_outdated_formulae() {
  # Purpose: list outdated formulae
  # Notes: do NOT upgrade here
  brew outdated --formula 2>/dev/null || true
}

_brew_outdated_casks() {
  # Purpose: list outdated casks
  brew outdated --cask 2>/dev/null || true
}

_brew_top_n_largest_formulae() {
  # Purpose: print top N largest formulae by Cellar size
  # Inputs: N
  # Performance: single-pass scan of Cellar/* instead of one `du` per formula.
  local n="${1:-10}"

  local prefix
  prefix="$(_brew_prefix)"
  [[ -n "$prefix" ]] || return 0

  local cellar="$prefix/Cellar"
  [[ -d "$cellar" ]] || return 0

  local tmp
  tmp="$(_brew_tmpfile)"
  [[ -n "${tmp:-}" ]] || return 0
  : > "${tmp}"

  # `du -sk Cellar/*` yields: <kb> <path>
  # Convert to MB and capture the formula name from the directory basename.
  du -sk "$cellar"/* 2>/dev/null \
    | awk '{kb=$1; $1=""; sub(/^\s+/,"",$0); if(kb ~ /^[0-9]+$/ && length($0)>0) print kb"\t"$0; }' \
    | while IFS=$'\t' read -r kb p; do
        [[ -n "${kb:-}" && -n "${p:-}" ]] || continue
        local f
        f="$(basename "$p" 2>/dev/null || echo "")"
        [[ -n "$f" ]] || continue
        local mb
        mb="$(_brew_kb_to_mb "$kb")"
        { printf "%s|%s\n" "$mb" "$f"; } >> "${tmp}" 2>/dev/null || true
      done

  # Sort by size desc and print top N.
  while IFS='|' read -r mb f; do
    [[ -n "$f" ]] || continue

    # Versions: avoid `brew` calls; list version directories under Cellar/<formula>.
    local versions_list=()
    local v
    for v in "$cellar/$f"/*; do
      [[ -e "$v" ]] || continue
      [[ -d "$v" ]] || continue
      versions_list+=("$(basename "$v" 2>/dev/null || printf '%s' '')")
    done
    local versions
    versions="$(printf '%s\n' "${versions_list[@]}" | _brew_sorted_unique_lines || true)"
    versions=$(printf '%s\n' "$versions" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | sed -E 's/[[:space:]]+$//')

    log "BREW SIZE: ${f} | ${mb}MB | versions: ${versions:-unknown}"
    BREW_TOP_SIZES+=("${f}|${mb}|${versions:-unknown}")
    if [[ "${BREW_EXPLAIN}" == "true" ]]; then
      explain_log "  source: Cellar size (single-pass scan)"
    fi
  done < <(sort -t '|' -k1,1nr "${tmp}" 2>/dev/null | head -n "$n" 2>/dev/null)
}

_brew_cache_downloads_summary() {
  # Purpose: summarize Homebrew cache (root + downloads)
  # Notes: read-only; safe
  local cache_root="$HOME/Library/Caches/Homebrew"
  local downloads_dir="$cache_root/downloads"

  [[ -d "$cache_root" ]] || return 0

  local root_mb
  root_mb="$(_brew_dir_mb "$cache_root")"
  local cache_root_disp
  cache_root_disp="$(_brew_display_path "${cache_root}")"
  log "BREW CACHE: Homebrew | ${root_mb}MB | path: ${cache_root_disp}"
  BREW_CACHE_LINES+=("BREW CACHE: Homebrew | ${root_mb}MB | path: ${cache_root_disp}")

  if [[ "${BREW_EXPLAIN}" == "true" ]]; then
    # Top 3 subfolders by size (best-effort)
    # Avoid temp files and redirections here to prevent weird failure modes under piped output.
    find "$cache_root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null \
      | while IFS= read -r -d '' d; do
          local mb
          mb="$(_brew_dir_mb "$d")"
          { printf "%s|%s\n" "$mb" "$d"; } 2>/dev/null || true
        done \
      | sort -t '|' -k1,1nr 2>/dev/null \
      | head -n 3 2>/dev/null \
      | while IFS='|' read -r mb p; do
          [[ -n "${p:-}" ]] || continue
          explain_log "  cache subdir: ${mb}MB | $(_brew_display_path "${p}")"
        done
  fi

  [[ -d "$downloads_dir" ]] || return 0

  local total_mb
  total_mb="$(_brew_dir_mb "$downloads_dir")"

  local count
  count=$(find "$downloads_dir" -type f 2>/dev/null | wc -l | tr -d ' ' || echo "0")

  # Oldest file mtime (best-effort)
  local oldest
  oldest=$(find "$downloads_dir" -type f -print0 2>/dev/null \
    | xargs -0 stat -f "%m %N" 2>/dev/null \
    | sort -n \
    | head -n 1 \
    | awk '{print $1}' || true)

  if [[ -n "$oldest" ]]; then
    local oldest_h
    oldest_h=$(date -r "$oldest" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")
    log "BREW CACHE: downloads | ${total_mb}MB | files: ${count} | oldest: ${oldest_h}"
    BREW_CACHE_LINES+=("BREW CACHE: downloads | ${total_mb}MB | files: ${count} | oldest: ${oldest_h}")
  else
    log "BREW CACHE: downloads | ${total_mb}MB | files: ${count}"
    BREW_CACHE_LINES+=("BREW CACHE: downloads | ${total_mb}MB | files: ${count}")
  fi
}

# ----------------------------
# Module Entry Point
# ----------------------------
run_brew_module() {
  # Contract:
  #   run_brew_module <mode> <apply> <backup_dir> <explain> [inventory_index_file]
  local mode="${1:-scan}"
  local apply="${2:-false}"
  local backup_dir="${3:-}"
  local explain="${4:-false}"
  local inventory_index_file="${5:-}"

  # Reserved args for contract consistency.
  : "${mode}" "${backup_dir}" "${inventory_index_file}"

  # Module-scoped explain flag (do not mutate global EXPLAIN)
  BREW_EXPLAIN="${explain}"

  # Inputs
  log "Homebrew: mode=${mode} apply=${apply} backup_dir=${backup_dir} explain=${explain} (read-only module; apply ignored)"

  # Stable exported summary fields (must be set even on early returns).
  BREW_FLAGGED_COUNT="0"
  BREW_FLAGGED_IDS_LIST=""
  BREW_FORMULAE_COUNT="0"
  BREW_CASKS_COUNT="0"
  BREW_OUTDATED_UNPINNED_COUNT="0"
  BREW_OUTDATED_PINNED_COUNT="0"
  BREW_LEAVES_COUNT="0"
  BREW_DUR_S=0

  # Timing + temp cleanup (RETURN trap)
  local _brew_t0="" _brew_t1=""
  _brew_t0="$(/bin/date +%s 2>/dev/null || printf '')"

  _brew_finish_timing() {
    _brew_t1="$(/bin/date +%s 2>/dev/null || printf '')"
    if [[ "${_brew_t0:-}" =~ ^[0-9]+$ && "${_brew_t1:-}" =~ ^[0-9]+$ ]]; then
      BREW_DUR_S=$((_brew_t1 - _brew_t0))
    else
      BREW_DUR_S=0
    fi
  }

  _brew_tmp_cleanup() {
    local f
    for f in "${BREW_TMPFILES[@]:-}"; do
      [[ -n "${f}" && -e "${f}" ]] && rm -f "${f}" 2>/dev/null || true
    done
    BREW_TMPFILES=()
  }

  _brew_on_return() {
    _brew_finish_timing
    _brew_tmp_cleanup
  }
  trap _brew_on_return RETURN


  # Reset summary buckets per run
  BREW_LEAVES_LIST=()
  BREW_OUTDATED_UNPINNED=()
  BREW_OUTDATED_PINNED=()
  BREW_TOP_SIZES=()
  BREW_CACHE_LINES=()
  BREW_FLAGGED_ITEMS=()

  if ! _brew_exists; then
    log "Homebrew not found, skipping brew hygiene."
    if type summary_add >/dev/null 2>&1; then
      summary_add "brew" "present=false formulae=0 casks=0 outdated_unpinned=0 outdated_pinned=0 leaves=0 flagged=0"
    fi
    return 0
  fi

  log "Homebrew: scanning installation (inspection-first)..."

  if [[ "${BREW_EXPLAIN}" == "true" ]]; then
    if [[ "${INVENTORY_READY:-false}" == "true" ]]; then
      if [[ -n "${INVENTORY_BREW_FORMULAE_FILE:-}" || -n "${INVENTORY_BREW_FORMULAE:-}" ]]; then
        explain_log "Inventory (brew): using inventory-provided formula list"
      else
        explain_log "Inventory (brew): no formula list provided; using brew list"
      fi
      if [[ -n "${INVENTORY_BREW_CASKS_FILE:-}" || -n "${INVENTORY_BREW_CASKS:-}" ]]; then
        explain_log "Inventory (brew): using inventory-provided cask list"
      else
        explain_log "Inventory (brew): no cask list provided; using brew list"
      fi
    fi
  fi

  local formulae
  local casks
  formulae="$(_brew_list_formulae)"
  casks="$(_brew_list_casks)"

  local n_formulae
  local n_casks
  n_formulae=$(printf '%s\n' "$formulae" | awk 'NF' | wc -l | tr -d ' ' || printf '0')
  n_casks=$(printf '%s\n' "$casks" | awk 'NF' | wc -l | tr -d ' ' || printf '0')

  log "BREW SUMMARY:"
  log "  formulas: ${n_formulae}"
  log "  casks: ${n_casks}"
  BREW_FORMULAE_COUNT="${n_formulae}"
  BREW_CASKS_COUNT="${n_casks}"

  # Leaves (not depended on by other formulae). Leaves are not necessarily unused.
  local leaves
  leaves="$(_brew_leaves)"
  if [[ -n "$leaves" ]]; then
    log "BREW LEAVES (not depended on by other formulae):"
    if [[ "${BREW_EXPLAIN}" == "true" ]]; then
      explain_log "  note: leaves may still be actively used (explicit installs)."
    fi
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      BREW_LEAVES_LIST+=("$f")
      log "  ${f}"
      if [[ "${BREW_EXPLAIN}" == "true" ]]; then
        explain_log "    reason: brew leaves (no other formula depends on it)"
      fi
    done <<< "$(printf '%s\n' "$leaves" | awk 'NF')"
  else
    log "BREW LEAVES (not depended on by other formulae): none"
  fi
  BREW_LEAVES_COUNT="$(_brew_array_len BREW_LEAVES_LIST)"

  # Outdated (split pinned vs unpinned)
  local outdated_f
  local outdated_c
  local pinned_f

  outdated_f="$(_brew_outdated_formulae)"
  outdated_c="$(_brew_outdated_casks)"
  pinned_f="$(_brew_list_pinned_formulae)"

  # Build a fast lookup string for pinned formulae (newline wrapped)
  local pinned_lookup
  pinned_lookup="$(printf "\n%s\n" "$pinned_f")"

  local outdated_unpinned=""
  local outdated_pinned=""

  if [[ -n "$outdated_f" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      # First token is the formula name (brew outdated prints just the name)
      local name
      name="$(echo "$line" | awk '{print $1}')"
      if printf '%s\n' "$pinned_lookup" | grep -Fq $'\n'"$name"$'\n'; then
        outdated_pinned="${outdated_pinned}${line}"$'\n'
        BREW_OUTDATED_PINNED+=("$name")
      else
        outdated_unpinned="${outdated_unpinned}${line}"$'\n'
        BREW_OUTDATED_UNPINNED+=("$name")
        BREW_FLAGGED_ITEMS+=("outdated:${name}")
      fi
    done <<< "$outdated_f"
  fi

  if [[ -n "$outdated_unpinned" ]]; then
    log "BREW OUTDATED (formulae):"
    printf '%s\n' "$outdated_unpinned" | awk 'NF' | while IFS= read -r line; do
      log "  ${line}"
    done
  else
    log "BREW OUTDATED (formulae): none"
  fi

  if [[ -n "$outdated_pinned" ]]; then
    log "BREW OUTDATED BUT PINNED (formulae):"
    printf '%s\n' "$outdated_pinned" | awk 'NF' | while IFS= read -r line; do
      log "  ${line}"
      if [[ "${BREW_EXPLAIN}" == "true" ]]; then
        explain_log "    note: pinned formulae are excluded from brew upgrade"
      fi
    done
  fi

  if [[ -n "$outdated_c" ]]; then
    log "BREW OUTDATED (casks):"
    printf '%s\n' "$outdated_c" | awk 'NF' | while IFS= read -r line; do
      log "  ${line}"
    done
  else
    log "BREW OUTDATED (casks): none"
  fi
  BREW_OUTDATED_UNPINNED_COUNT="$(_brew_array_len BREW_OUTDATED_UNPINNED)"
  BREW_OUTDATED_PINNED_COUNT="$(_brew_array_len BREW_OUTDATED_PINNED)"

  # Disk usage top N
  log "BREW DISK USAGE (top 10 formulae by Cellar size):"
  _brew_top_n_largest_formulae 10

  # Downloads cache summary
  _brew_cache_downloads_summary

  log "Homebrew: inspection complete."

  # ----------------------------
  # Summary (actionable items at end)
  # ----------------------------
  log "Homebrew: flagged items:"
  local flags_len
  flags_len="$(_brew_array_len BREW_FLAGGED_ITEMS)"
  if [[ "$flags_len" -gt 0 ]]; then
    for item in "${BREW_FLAGGED_ITEMS[@]}"; do
      log "  - ${item}"
    done
  else
    log "  none"
  fi

  log "BREW SUMMARY (review list):"

  if (( ${#BREW_OUTDATED_UNPINNED[@]} > 0 )); then
    log "  Outdated (unpinned):"
    for f in "${BREW_OUTDATED_UNPINNED[@]}"; do
      log "    - ${f}"
    done
  else
    log "  Outdated (unpinned): none"
  fi

  if (( ${#BREW_OUTDATED_PINNED[@]} > 0 )); then
    log "  Outdated but pinned:"
    for f in "${BREW_OUTDATED_PINNED[@]}"; do
      log "    - ${f}"
    done
  else
    log "  Outdated but pinned: none"
  fi

  if (( ${#BREW_TOP_SIZES[@]} > 0 )); then
    log "  Largest formulae (top 10 by Cellar size):"
    for entry in "${BREW_TOP_SIZES[@]}"; do
      local name
      local rest
      local mb
      local ver
      name="${entry%%|*}"
      rest="${entry#*|}"
      mb="${rest%%|*}"
      ver="${rest#*|}"
      log "    - ${name}: ${mb}MB (versions: ${ver})"
    done
  else
    log "  Largest formulae: none"
  fi

  if (( ${#BREW_CACHE_LINES[@]} > 0 )); then
    log "  Cache highlights:"
    for line in "${BREW_CACHE_LINES[@]}"; do
      log "    - ${line#BREW CACHE: }"
    done
  else
    log "  Cache highlights: none"
  fi

  if (( ${#BREW_LEAVES_LIST[@]} > 0 )); then
    log "  Leaves (informational, not necessarily unused):"
    for f in "${BREW_LEAVES_LIST[@]}"; do
      log "    - ${f}"
    done
  else
    log "  Leaves: none"
  fi

  log "Homebrew: inspection-only (read-only). No cleanup actions are performed."

  # Export flagged identifiers list for run summary consumption.
  BREW_FLAGGED_COUNT="$(_brew_array_len BREW_FLAGGED_ITEMS)"
  BREW_FLAGGED_IDS_LIST="$({ printf '%s\n' "${BREW_FLAGGED_ITEMS[@]:-}"; } 2>/dev/null || true)"

  # ----------------------------
  # Global summary hook
  # ----------------------------
  if type summary_add >/dev/null 2>&1; then
    summary_add "brew" "present=true formulae=${BREW_FORMULAE_COUNT} casks=${BREW_CASKS_COUNT} outdated_unpinned=${BREW_OUTDATED_UNPINNED_COUNT} outdated_pinned=${BREW_OUTDATED_PINNED_COUNT} leaves=${BREW_LEAVES_COUNT} flagged=${BREW_FLAGGED_COUNT}"
  fi
}

# End of module
