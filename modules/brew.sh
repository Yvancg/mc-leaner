#!/bin/bash
# shellcheck shell=bash
# mc-leaner: brew module (inspection-first)
# Purpose: provide visibility into Homebrew state and disk usage
# Safety: read-only; does NOT run brew cleanup/uninstall/upgrade; no filesystem writes
# Notes: best-effort parsing; macOS default bash 3.2 compatible


# NOTE: Modules run with strict mode for deterministic failures and auditability.
set -euo pipefail

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
# Defensive Checks
# ----------------------------
if ! type explain_log >/dev/null 2>&1; then
  explain_log() {
    # Purpose: Best-effort verbose logging when --explain is enabled.
    # Safety: Logging only.
    if [[ "${EXPLAIN:-false}" == "true" ]]; then
      log "$@"
    fi
  }
fi

# ----------------------------
# Helpers
# ----------------------------

if ! type tmpfile >/dev/null 2>&1; then
  tmpfile() {
    # Purpose: Create a temp file path.
    # Safety: Creates an empty temp file.
    mktemp -t mc-leaner.XXXXXX
  }
fi

_brew_array_len() {
  # Purpose: safe array length under `set -u` (returns 0 if unset)
  # Inputs: variable name
  local name="$1"

  # `declare -a foo` (without assignment) makes `declare -p foo` succeed even though
  # expanding `${foo[@]}` still errors under `set -u`. So we must check "is set" too.
  if declare -p "$name" >/dev/null 2>&1; then
    if eval '[[ ${'"$name"'[@]+x} ]]'; then
      eval "echo \${#$name[@]}"
    else
      echo 0
    fi
  else
    echo 0
  fi
}

_brew_array_copy() {
  # Purpose: copy array values safely under `set -u`
  # Inputs: src var name, dest var name
  local src="$1"
  local dest="$2"

  # Same nuance as `_brew_array_len`: declared-but-unset arrays must be treated as empty.
  if declare -p "$src" >/dev/null 2>&1; then
    if eval '[[ ${'"$src"'[@]+x} ]]'; then
      eval "$dest=(\"\${$src[@]}\")"
    else
      eval "$dest=()"
    fi
  else
    eval "$dest=()"
  fi
}
_brew_exists() {
  # Purpose: check whether Homebrew is installed
  command -v brew >/dev/null 2>&1
}

_brew_prefix() {
  # Purpose: return brew prefix (best-effort)
  # Safety: read-only
  brew --prefix 2>/dev/null || echo ""
}

_brew_kb_to_mb() {
  # Purpose: convert KB to MB (integer)
  local kb="${1:-0}"
  echo $((kb / 1024))
}

_brew_dir_mb() {
  # Purpose: return directory size in MB (integer)
  # Notes: du -sk is stable across macOS
  local p="$1"
  local kb
  kb=$(du -sk "$p" 2>/dev/null | awk '{print $1}' || echo "0")
  _brew_kb_to_mb "$kb"
}

_brew_sorted_unique_lines() {
  # Purpose: normalize text list (sorted unique)
  # Usage: echo "$text" | _brew_sorted_unique_lines
  sort | awk 'NF' | uniq
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
  tmp="$(tmpfile)"
  : > "$tmp"

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
        printf "%s|%s\n" "$mb" "$f" >> "$tmp"
      done

  # Sort by size desc and print top N.
  sort -t '|' -k1,1nr "$tmp" 2>/dev/null | head -n "$n" | while IFS='|' read -r mb f; do
    [[ -n "$f" ]] || continue

    # Versions: avoid `brew` calls; list version directories under Cellar/<formula>.
    local versions
    versions=$(ls -1 "$cellar/$f" 2>/dev/null | _brew_sorted_unique_lines || true)
    versions=$(echo "$versions" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | sed -E 's/[[:space:]]+$//')

    log "BREW SIZE: ${f} | ${mb}MB | versions: ${versions:-unknown}"
    BREW_TOP_SIZES+=("${f}|${mb}|${versions:-unknown}")
    if [[ "${EXPLAIN:-false}" == "true" ]]; then
      explain_log "  source: Cellar size (single-pass scan)"
    fi
  done
}

_brew_cache_downloads_summary() {
  # Purpose: summarize Homebrew cache (root + downloads)
  # Notes: read-only; safe
  local cache_root="$HOME/Library/Caches/Homebrew"
  local downloads_dir="$cache_root/downloads"

  [[ -d "$cache_root" ]] || return 0

  local root_mb
  root_mb="$(_brew_dir_mb "$cache_root")"
  log "BREW CACHE: Homebrew | ${root_mb}MB | path: ${cache_root}"
  BREW_CACHE_LINES+=("BREW CACHE: Homebrew | ${root_mb}MB | path: ${cache_root}")

  if [[ "${EXPLAIN:-false}" == "true" ]]; then
    # Top 3 subfolders by size (best-effort)
    local tmp
    tmp="$(tmpfile)"
    : > "$tmp"
    find "$cache_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r d; do
      local mb
      mb="$(_brew_dir_mb "$d")"
      printf "%s|%s\n" "$mb" "$d" >> "$tmp"
    done
    sort -t '|' -k1,1nr "$tmp" 2>/dev/null | head -n 3 | while IFS='|' read -r mb p; do
      [[ -n "$p" ]] || continue
      explain_log "  subfolder: ${mb}MB | ${p}"
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
  # Args:
  #  $1 apply (true/false)  [ignored; module is inspection-only]
  #  $2 backup dir          [ignored]
  #  $3 explain (true/false)
  local _apply="$1"
  local _backup_dir="$2"
  local explain="$3"

  # Inputs
  log "Homebrew: mode=brew-only apply=${_apply} backup_dir=${_backup_dir} explain=${explain} (read-only module; apply ignored)"

  EXPLAIN="$explain"

  # Defensive: make sure summary arrays exist even if this file is sourced in an unexpected order
  declare -a BREW_LEAVES_LIST BREW_OUTDATED_UNPINNED BREW_OUTDATED_PINNED BREW_TOP_SIZES BREW_CACHE_LINES BREW_FLAGGED_ITEMS

  # Reset summary buckets per run
  BREW_LEAVES_LIST=()
  BREW_OUTDATED_UNPINNED=()
  BREW_OUTDATED_PINNED=()
  BREW_TOP_SIZES=()
  BREW_CACHE_LINES=()
  BREW_FLAGGED_ITEMS=()

  if ! _brew_exists; then
    log "Homebrew not found, skipping brew hygiene."
    return 0
  fi

  log "Homebrew: scanning installation (inspection-first)..."

  if [[ "${EXPLAIN:-false}" == "true" ]]; then
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
  n_formulae=$(echo "$formulae" | awk 'NF' | wc -l | tr -d ' ' || echo "0")
  n_casks=$(echo "$casks" | awk 'NF' | wc -l | tr -d ' ' || echo "0")

  log "BREW SUMMARY:"
  log "  formulas: ${n_formulae}"
  log "  casks: ${n_casks}"

  # Leaves (not depended on by other formulae). Leaves are not necessarily unused.
  local leaves
  leaves="$(_brew_leaves)"
  if [[ -n "$leaves" ]]; then
    log "BREW LEAVES (not depended on by other formulae):"
    if [[ "${EXPLAIN:-false}" == "true" ]]; then
      explain_log "  note: leaves may still be actively used (explicit installs)."
    fi
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      BREW_LEAVES_LIST+=("$f")
      log "  ${f}"
      if [[ "${EXPLAIN:-false}" == "true" ]]; then
        explain_log "    reason: brew leaves (no other formula depends on it)"
      fi
    done <<< "$(echo "$leaves" | awk 'NF')"
  else
    log "BREW LEAVES (not depended on by other formulae): none"
  fi

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
      if echo "$pinned_lookup" | grep -Fq $'\n'"$name"$'\n'; then
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
    echo "$outdated_unpinned" | awk 'NF' | while IFS= read -r line; do
      log "  ${line}"
    done
  else
    log "BREW OUTDATED (formulae): none"
  fi

  if [[ -n "$outdated_pinned" ]]; then
    log "BREW OUTDATED BUT PINNED (formulae):"
    echo "$outdated_pinned" | awk 'NF' | while IFS= read -r line; do
      log "  ${line}"
      if [[ "${EXPLAIN:-false}" == "true" ]]; then
        explain_log "    note: pinned formulae are excluded from brew upgrade"
      fi
    done
  fi

  if [[ -n "$outdated_c" ]]; then
    log "BREW OUTDATED (casks):"
    echo "$outdated_c" | awk 'NF' | while IFS= read -r line; do
      log "  ${line}"
    done
  else
    log "BREW OUTDATED (casks): none"
  fi

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

  # ----------------------------
  # Global summary hook
  # ----------------------------
  # Note: under `set -u`, expanding an unset array errors. Defensive-copy to a local array.
  local -a _brew_flags
  _brew_array_copy BREW_FLAGGED_ITEMS _brew_flags

  local brew_flags_len
  brew_flags_len="$(_brew_array_len _brew_flags)"

  if [[ "$brew_flags_len" -gt 0 ]]; then
    summary_add "brew" \
      "formulae=${n_formulae}, casks=${n_casks}, outdated_unpinned=${#BREW_OUTDATED_UNPINNED[@]}, leaves=${#BREW_LEAVES_LIST[@]}" \
      "${_brew_flags[@]}"
  else
    summary_add "brew" \
      "formulae=${n_formulae}, casks=${n_casks}, outdated_unpinned=${#BREW_OUTDATED_UNPINNED[@]}, leaves=${#BREW_LEAVES_LIST[@]}"
  fi
}
