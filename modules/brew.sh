#!/bin/bash
# mc-leaner: brew module (inspection-first)
# Purpose: provide visibility into Homebrew state and disk usage
# Safety: read-only; does NOT run brew cleanup/uninstall/upgrade; no filesystem writes
# Notes: best-effort parsing; macOS default bash 3.2 compatible

set -euo pipefail

# ----------------------------
# Defensive: ensure explain_log exists
# ----------------------------
if ! type explain_log >/dev/null 2>&1; then
  explain_log() {
    # Purpose: best-effort verbose logging when --explain is enabled
    # Safety: logging only
    if [[ "${EXPLAIN:-false}" == "true" ]]; then
      log "$@"
    fi
  }
fi

# ----------------------------
# Helpers
# ----------------------------
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
  brew list --formula 2>/dev/null || true
}

_brew_list_casks() {
  # Purpose: list installed casks
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

_brew_versions_for_formula() {
  # Purpose: list installed versions for a formula (best-effort)
  # Inputs: formula name
  local f="$1"

  # Homebrew prints: <formula>: <version> [<version> ...]
  # If not supported, fall back to cellar directories.
  local out
  out=$(brew list --versions "$f" 2>/dev/null || true)
  if [[ -n "$out" ]]; then
    echo "$out" | awk '{ $1=""; sub(/^ /, ""); print }'
    return 0
  fi

  # Fallback: inspect Cellar folder
  local prefix
  prefix="$(_brew_prefix)"
  [[ -n "$prefix" ]] || return 0

  local cellar="$prefix/Cellar/$f"
  [[ -d "$cellar" ]] || return 0

  ls -1 "$cellar" 2>/dev/null | _brew_sorted_unique_lines
}

_brew_formula_size_mb() {
  # Purpose: compute total size for a formula across installed versions
  # Inputs: formula name
  local f="$1"

  local prefix
  prefix="$(_brew_prefix)"
  [[ -n "$prefix" ]] || { echo "0"; return 0; }

  local cellar="$prefix/Cellar/$f"
  [[ -d "$cellar" ]] || { echo "0"; return 0; }

  _brew_dir_mb "$cellar"
}

_brew_top_n_largest_formulae() {
  # Purpose: print top N largest formulae by Cellar size
  # Inputs: N
  local n="${1:-10}"

  local formulae
  formulae="$(_brew_list_formulae)"
  [[ -n "$formulae" ]] || return 0

  local tmp
  tmp="$(tmpfile)"
  : > "$tmp"

  echo "$formulae" | while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    local mb
    mb="$(_brew_formula_size_mb "$f")"
    printf "%s|%s\n" "$mb" "$f" >> "$tmp"
  done

  sort -t '|' -k1,1nr "$tmp" 2>/dev/null | head -n "$n" | while IFS='|' read -r mb f; do
    [[ -n "$f" ]] || continue
    local versions
    versions="$(_brew_versions_for_formula "$f")"
    # Collapse versions to one line
    versions=$(echo "$versions" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | sed -E 's/[[:space:]]+$//')

    log "BREW SIZE: ${f} | ${mb}MB | versions: ${versions:-unknown}"

    if [[ "${EXPLAIN:-false}" == "true" ]]; then
      explain_log "  source: Cellar size (best-effort)"
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
  else
    log "BREW CACHE: downloads | ${total_mb}MB | files: ${count}"
  fi
}

# ----------------------------
# Entry point
# ----------------------------
run_brew_module() {
  # Args:
  #  $1 apply (true/false)  [ignored; brew module is read-only in v1.3.0]
  #  $2 backup dir          [ignored]
  #  $3 explain (true/false)
  local _apply="$1"
  local _backup_dir="$2"
  local explain="$3"

  EXPLAIN="$explain"

  if ! _brew_exists; then
    log "Homebrew not found, skipping brew hygiene."
    return 0
  fi

  log "Homebrew: scanning installation (inspection-first)..."

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
    echo "$leaves" | awk 'NF' | while IFS= read -r f; do
      log "  ${f}"
      if [[ "${EXPLAIN:-false}" == "true" ]]; then
        explain_log "    reason: brew leaves (no other formula depends on it)"
      fi
    done
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
      if echo "$pinned_lookup" | grep -q $'\n'"$name"$'\n'; then
        outdated_pinned="${outdated_pinned}${line}"$'\n'
      else
        outdated_unpinned="${outdated_unpinned}${line}"$'\n'
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
  log "Homebrew: v1.3.0 is read-only. No cleanup actions are performed."
}
