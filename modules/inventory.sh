#!/usr/bin/env bash
# shellcheck shell=bash
# mc-leaner: inventory
#
# Purpose:
#   Build a canonical inventory of installed software so other modules can attribute
#   files/folders to an installed owner.
#
# Contract:
#   - Inspection-only. No deletions, moves, or system changes.
#   - Produces TSV artifacts and exports globals for cross-module lookups.
#
# Inputs:
#   - Filesystem app roots: /System/Applications, /Applications, $HOME/Applications
#   - Optional: Homebrew (if `brew` is present)
#
# Outputs (exported globals):
#   - INVENTORY_FILE (TSV): kind\tsource\tname\tbundle_id\tapp_path\tbrew_id
#   - INVENTORY_INDEX_FILE (TSV): key\tname\tsource\tapp_path
#   - INVENTORY_READY: true/false
#   - INVENTORY_BREW_BINS_FILE (optional): newline list of brew executable basenames
#   - INVENTORY_BREW_BINS_READY: true/false
#   - INVENTORY_CACHE_READY: true/false (associative-array cache when supported)
#
# Notes:
#   - App discovery uses `find -L` to capture symlinked Apple apps (Cryptex).
#   - Bundle id resolution is best-effort (mdls, then Info.plist).

# NOTE: This module uses best-effort probing across app roots and optional Homebrew.
# It enables `set -u` and `pipefail` but avoids `set -e` to prevent aborting on expected absence/permission errors.
set -uo pipefail

#
# ----------------------------
# Exported Globals
# ----------------------------
# These are exported for other modules.
INVENTORY_FILE=""
INVENTORY_INDEX_FILE=""
INVENTORY_READY="false"

# Optional derived index: list of Homebrew-provided executable basenames (from prefix/bin + prefix/sbin).
INVENTORY_BREW_BINS_FILE=""
INVENTORY_BREW_BINS_READY="false"

# Optional in-memory cache for inventory lookups (only if bash supports associative arrays).
INVENTORY_CACHE_READY="false"
# Keys are inventory index keys; values are the full hit line: name\tsource\tapp_path

#
# ----------------------------
# Logging Helpers
# ----------------------------
_inventory_log() {
  # Purpose: Centralize inventory logging.
  # Safety: Logging only.
  if command -v log >/dev/null 2>&1; then
    # shellcheck disable=SC2154
    log "$@"
  else
    printf '%s\n' "$*"
  fi
}

_inventory_debug() {
  # shellcheck disable=SC2154
  if [[ "${EXPLAIN:-false}" == "true" ]]; then
    log "Inventory (explain): $*"
  fi
}

#
# ----------------------------
# Temp Files
# ----------------------------
_inventory_tmpfile() {
  # Purpose: Create a temp file (template first, then fallback).
  local f=""
  f="$(mktemp -t mc-leaner_inventory.XXXXXX 2>/dev/null || true)"
  if [[ -z "$f" ]]; then
    f="$(mktemp 2>/dev/null || true)"
  fi
  echo "$f"
}

#
# ----------------------------
# TSV Helpers
# ----------------------------
_inventory_sanitize_tsv() {
  # Purpose: Sanitize a field so it is safe to write into a TSV.
  local s="$1"
  s="${s//$'\t'/ }"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/ }"
  echo "$s"
}

#
# ----------------------------
# Lookup Cache
# ----------------------------
_inventory_enable_cache_if_supported() {
  # Purpose: Enable an associative-array lookup cache when Bash supports it (>= 4).
  if [[ -n "${BASH_VERSINFO:-}" && "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
    # Re-declare each time to ensure correct type, then clear.
    unset -v INVENTORY_CACHE_HITS 2>/dev/null || true
    # shellcheck disable=SC2034
    declare -gA INVENTORY_CACHE_HITS
    INVENTORY_CACHE_READY="true"
  else
    INVENTORY_CACHE_READY="false"
  fi
}

#
# ----------------------------
# App Metadata
# ----------------------------
_inventory_bundle_id_for_app() {
  # Purpose: Return the bundle id for an app bundle (best-effort).
  local app_path="$1"
  local bid=""

  # mdls is fast and non-invasive. It returns (null) if not present.
  bid="$(mdls -name kMDItemCFBundleIdentifier -raw "$app_path" 2>/dev/null || true)"
  if [[ "$bid" == "(null)" ]]; then
    bid=""
  fi

  if [[ -z "$bid" ]]; then
    # Fallback: read Info.plist (PlistBuddy is more reliable than defaults for file paths)
    local plist="$app_path/Contents/Info.plist"
    if [[ -f "$plist" ]]; then
      bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
    fi
  fi

  echo "$bid"
}

#
# ----------------------------
# Index Writers
# ----------------------------
_inventory_add_row() {
  # kind source name bundle_id app_path brew_id
  local kind="$1"; shift
  local source="$1"; shift
  local name="$1"; shift
  local bundle_id="$1"; shift
  local app_path="$1"; shift
  local brew_id="$1"; shift

  name="$(_inventory_sanitize_tsv "$name")"
  bundle_id="$(_inventory_sanitize_tsv "$bundle_id")"
  app_path="$(_inventory_sanitize_tsv "$app_path")"
  brew_id="$(_inventory_sanitize_tsv "$brew_id")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$source" "$name" "$bundle_id" "$app_path" "$brew_id" >> "$INVENTORY_FILE"
}

_inventory_add_index() {
  # key name source app_path
  local key="$1"; shift
  local name="$1"; shift
  local source="$1"; shift
  local app_path="$1"; shift

  key="$(_inventory_sanitize_tsv "$key")"
  name="$(_inventory_sanitize_tsv "$name")"
  app_path="$(_inventory_sanitize_tsv "$app_path")"

  # Defensive: `name` must be human-readable. If it accidentally carries a path key,
  # normalize it back to an app-like display name.
  if [[ "$name" == path:* ]]; then
    local p_from_name base_from_name
    p_from_name="${name#path:}"
    base_from_name="$(basename "$p_from_name" 2>/dev/null || true)"
    base_from_name="${base_from_name%.app}"
    if [[ -n "$base_from_name" ]]; then
      name="$base_from_name"
    fi
  fi

  if [[ -z "$key" ]]; then
    return 0
  fi

  printf '%s\t%s\t%s\t%s\n' "$key" "$name" "$source" "$app_path" >> "$INVENTORY_INDEX_FILE"
}

_inventory_normalize_app_key() {
  # Purpose: Normalize an app name into a conservative inventory key.
  # Safety: Conservative normalization reduces false-positive ownership matches.
  local s="$1"
  s="${s%.app}"
  # lowercase
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
  # strip spaces
  s="${s// /}"
  echo "$s"
}

#
# ----------------------------
# App Scanning
# ----------------------------
_inventory_scan_apps_root() {
  local root="$1"
  local source="$2"

  if [[ ! -d "$root" ]]; then
    return 0
  fi

  _inventory_debug "app scan root: $root (source=$source)"

  local app
  while IFS= read -r -d '' app; do
    local base name bid effective_source target
    base="$(basename "$app")"
    name="${base%.app}"

    # If the .app is a symlink, use its resolved target to decide whether it is a system app.
    # On newer macOS builds, some Apple apps appear under /Applications but point into Cryptex.
    target=""
    if [[ -L "$app" ]]; then
      target="$(readlink "$app" 2>/dev/null || true)"
      # Resolve relative symlinks to an absolute path (best-effort).
      if [[ -n "$target" && "$target" != /* ]]; then
        # Build an absolute path by resolving the directory part via `cd`.
        local link_dir tgt_dir tgt_base
        link_dir="$(dirname "$app")"
        tgt_dir="$(dirname "$target")"
        tgt_base="$(basename "$target")"
        target="$(cd "$link_dir" 2>/dev/null && cd "$tgt_dir" 2>/dev/null && pwd)/$tgt_base"
      fi
    fi
    if [[ -z "$target" ]]; then
      target="$app"
    fi

    effective_source="$source"
    if [[ "$target" == /System/Applications/* || "$target" == /System/Cryptexes/App/System/Applications/* ]]; then
      effective_source="system"
    fi

    bid="$(_inventory_bundle_id_for_app "$app")"

    _inventory_add_row "app" "$effective_source" "$name" "$bid" "$app" ""

    # Also index app bundle paths (both visible and resolved target) so modules can
    # resolve ownership from concrete filesystem locations without schema changes.
    _inventory_add_index "path:$app" "$name" "$effective_source" "$app"
    if [[ -n "$target" && "$target" != "$app" ]]; then
      _inventory_add_index "path:$target" "$name" "$effective_source" "$app"
    fi

    # Index keys
    if [[ -n "$bid" ]]; then
      _inventory_add_index "$bid" "$name" "$effective_source" "$app"
    fi
    _inventory_add_index "$(_inventory_normalize_app_key "$base")" "$name" "$effective_source" "$app"
    _inventory_add_index "$(_inventory_normalize_app_key "$name")" "$name" "$effective_source" "$app"
  done < <(
    # Use `find -L` so we catch Apple Cryptex-installed apps that appear as symlinks in /Applications
    # (e.g. /Applications/Safari.app -> /System/Cryptexes/App/System/Applications/Safari.app).
    find -L "$root" -maxdepth 2 -type d -name "*.app" -print0 2>/dev/null
  )
}

#
# ----------------------------
# Homebrew Scanning
# ----------------------------
_inventory_have_brew() {
  command -v brew >/dev/null 2>&1
}

_inventory_scan_brew() {
  if ! _inventory_have_brew; then
    _inventory_debug "brew not found; skipping brew inventory"
    return 0
  fi

  _inventory_debug "brew present; scanning formulae/casks"

  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    _inventory_add_row "brew_formula" "brew" "$f" "" "" "$f"
    _inventory_add_index "brew:formula:$f" "$f" "brew" ""
  done < <(brew list --formula 2>/dev/null || true)

  local c
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    _inventory_add_row "brew_cask" "brew" "$c" "" "" "$c"
    _inventory_add_index "brew:cask:$c" "$c" "brew" ""
  done < <(brew list --cask 2>/dev/null || true)
}
_inventory_build_brew_bins() {
  # Build a fast membership list for other modules (e.g. /usr/local/bin heuristics).
  # Output: one executable basename per line, sorted unique (LC_ALL=C).

  INVENTORY_BREW_BINS_READY="false"
  INVENTORY_BREW_BINS_FILE=""

  if ! _inventory_have_brew; then
    return 0
  fi

  local prefix=""
  prefix="$(brew --prefix 2>/dev/null || true)"
  if [[ -z "$prefix" ]]; then
    _inventory_debug "brew present but prefix could not be determined; skipping brew bins"
    return 0
  fi

  local tmp=""
  tmp="$(_inventory_tmpfile)"
  if [[ -z "$tmp" || ! -e "$tmp" ]]; then
    return 0
  fi
  : > "$tmp"

  local d
  for d in "$prefix/bin" "$prefix/sbin"; do
    [[ -d "$d" ]] || continue

    # Enumerate only top-level executables (regular files or symlinks) to keep this fast.
    # Use -L to follow symlinks for permission checks; suppress permission errors.
    while IFS= read -r -d '' p; do
      local b
      b="$(basename "$p")"
      [[ -n "$b" ]] && printf '%s\n' "$b" >> "$tmp"
    done < <(find -L "$d" -maxdepth 1 \( -type f -o -type l \) -perm -111 -print0 2>/dev/null)
  done

  # If nothing collected, keep vars unset/false.
  local rows
  rows="$(awk 'END{print NR+0}' "$tmp" 2>/dev/null || echo 0)"
  if [[ "$rows" -le 0 ]]; then
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi

  # Sort unique, locale-stable.
  local out=""
  out="$(_inventory_tmpfile)"
  if [[ -z "$out" || ! -e "$out" ]]; then
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi

  if ! LC_ALL=C sort -u "$tmp" > "$out" 2>/dev/null; then
    rm -f "$tmp" "$out" 2>/dev/null || true
    return 0
  fi

  rm -f "$tmp" 2>/dev/null || true

  local final_rows
  final_rows="$(awk 'END{print NR+0}' "$out" 2>/dev/null || echo 0)"
  if [[ "$final_rows" -le 0 ]]; then
    rm -f "$out" 2>/dev/null || true
    return 0
  fi

  INVENTORY_BREW_BINS_FILE="$out"
  INVENTORY_BREW_BINS_READY="true"

  _inventory_debug "brew bins: ready=true entries=$final_rows file=$INVENTORY_BREW_BINS_FILE"
  return 0
}

#
# ----------------------------
# Index Maintenance
# ----------------------------
_inventory_dedupe_index_file() {
  # Deduplicate INVENTORY_INDEX_FILE in-place.
  # Index lookups only need one hit per key, so keeping the first match is fine.
  # We keep the FIRST occurrence in original order (stable dedupe), and remove any later duplicates.
  #
  # Format: key\tname\tsource\tapp_path

  local f="${INVENTORY_INDEX_FILE:-}"
  if [[ -z "$f" || ! -f "$f" ]]; then
    return 0
  fi

  # No work if 0/1 lines (avoid wc padding/locale quirks)
  local n="0"
  n="$(awk 'END{print NR+0}' "$f" 2>/dev/null || echo 0)"
  if [[ "$n" -le 1 ]]; then
    return 0
  fi

  local tmp=""
  tmp="$(_inventory_tmpfile)"
  if [[ -z "$tmp" || ! -e "$tmp" ]]; then
    return 0
  fi

  # Stable (first-seen) dedupe by key.
  # Only the FIRST occurrence of a key is kept.
  if ! awk -F'\t' 'NF>0 {k=$1; if (!(k in seen)) {seen[k]=1; print}}' "$f" > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi

  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 0; }
  return 0
}

#
# ----------------------------
# Public API
# ----------------------------
inventory_build() {
  # Public: build inventory files and export globals.
  # Respects EXPLAIN for verbose logging.

  INVENTORY_FILE="$(_inventory_tmpfile)"
  INVENTORY_INDEX_FILE="$(_inventory_tmpfile)"

  if [[ -z "$INVENTORY_FILE" || -z "$INVENTORY_INDEX_FILE" ]]; then
    _inventory_log "Inventory: failed to create temp files; skipping"
    INVENTORY_READY="false"
    return 1
  fi

  if [[ ! -e "$INVENTORY_FILE" || ! -e "$INVENTORY_INDEX_FILE" ]]; then
    _inventory_log "Inventory: temp files not created; skipping"
    INVENTORY_READY="false"
    return 1
  fi

  # Truncate
  : > "$INVENTORY_FILE"
  : > "$INVENTORY_INDEX_FILE"

  # Enable lookup cache when supported.
  _inventory_enable_cache_if_supported

  _inventory_log "Inventory: building installed software list (apps + Homebrew)..."

  # App roots
  _inventory_scan_apps_root "/System/Applications" "system"
  _inventory_scan_apps_root "/Applications" "user"
  _inventory_scan_apps_root "$HOME/Applications" "user"

  # Homebrew
  _inventory_scan_brew
  _inventory_build_brew_bins
  _inventory_dedupe_index_file

  # Summaries
  local apps_system apps_user brew_formula brew_cask
  apps_system="$(awk -F'\t' '$1=="app" && $2=="system" {c++} END{print c+0}' "$INVENTORY_FILE" 2>/dev/null || echo 0)"
  apps_user="$(awk -F'\t' '$1=="app" && $2=="user" {c++} END{print c+0}' "$INVENTORY_FILE" 2>/dev/null || echo 0)"
  brew_formula="$(awk -F'\t' '$1=="brew_formula" {c++} END{print c+0}' "$INVENTORY_FILE" 2>/dev/null || echo 0)"
  brew_cask="$(awk -F'\t' '$1=="brew_cask" {c++} END{print c+0}' "$INVENTORY_FILE" 2>/dev/null || echo 0)"

  local idx_lines
  idx_lines="$(awk 'END{print NR+0}' "$INVENTORY_INDEX_FILE" 2>/dev/null || echo 0)"

  _inventory_log "Inventory: apps system=$apps_system user=$apps_user; brew formulae=$brew_formula casks=$brew_cask; index_lines=$idx_lines"

  INVENTORY_READY="true"
  export INVENTORY_FILE INVENTORY_INDEX_FILE INVENTORY_READY INVENTORY_CACHE_READY
  export INVENTORY_BREW_BINS_FILE INVENTORY_BREW_BINS_READY
  return 0
}

inventory_lookup() {
  # Public: lookup by key in index.
  # Usage: inventory_lookup "com.apple.Safari"
  # Output: name\tsource\tapp_path (empty if not found)
  local key="$1"
  # Defensive: ignore empty keys and sanitize tabs/newlines to keep TSV/awk safe.
  if [[ -z "$key" ]]; then
    return 1
  fi
  key="${key//$'\t'/ }"
  key="${key//$'\n'/ }"
  key="${key//$'\r'/ }"

  if [[ "${INVENTORY_READY}" != "true" || -z "${INVENTORY_INDEX_FILE}" || ! -f "${INVENTORY_INDEX_FILE}" ]]; then
    return 1
  fi

  if [[ "$INVENTORY_CACHE_READY" == "true" ]]; then
    if [[ -n "${INVENTORY_CACHE_HITS["$key"]+x}" ]]; then
      printf '%s\n' "${INVENTORY_CACHE_HITS["$key"]}"
      return 0
    fi
  fi

  local line
  line="$(awk -F'\t' -v k="$key" '$1==k {print $2"\t"$3"\t"$4; found=1; exit} END{exit(found?0:1)}' "$INVENTORY_INDEX_FILE" 2>/dev/null)" || return 1

  if [[ "$INVENTORY_CACHE_READY" == "true" ]]; then
    INVENTORY_CACHE_HITS["$key"]="$line"
  fi

  printf '%s\n' "$line"
}

resolve_owner_from_path() {
  # Public: best-effort owner resolution.
  # Prints: owner_name|owner_key|owner_source|installed(true/false)
  local p="$1"
  local owner_name="Unknown"
  local owner_key=""
  local owner_source=""
  local installed="false"

  if [[ "${INVENTORY_READY}" != "true" ]]; then
    echo "${owner_name}|${owner_key}|${owner_source}|${installed}"
    return 0
  fi

  # 0) If the path is inside an app bundle, try a direct path-based lookup first.
  # This helps when we are given deep paths like:
  #   /Applications/Foo.app/Contents/...
  # Inventory indexes both the visible app path and the resolved target for symlinked apps.
  if [[ "$p" == *".app/"* ]]; then
    local app_dir
    app_dir="${p%%.app/*}.app"
    if [[ -n "$app_dir" ]]; then
      local hit
      if hit="$(inventory_lookup "path:$app_dir" 2>/dev/null)"; then
        local hit_name hit_source hit_path
        IFS=$'\t' read -r hit_name hit_source hit_path <<< "$hit"
        owner_name="$hit_name"
        owner_key="path:$app_dir"
        owner_source="$hit_source"
        installed="true"
        echo "${owner_name}|${owner_key}|${owner_source}|${installed}"
        return 0
      fi
    fi
  fi

  # 1) Bundle-id like paths (Containers, Group Containers, bundle-id cache folders)
  # Containers: ~/Library/Containers/<bundle-id>/...
  if [[ "$p" == *"/Library/Containers/"* ]]; then
    local rest
    rest="${p#*/Library/Containers/}"
    owner_key="${rest%%/*}"
  elif [[ "$p" == *"/Library/Group Containers/"* ]]; then
    local rest
    rest="${p#*/Library/Group Containers/}"
    owner_key="${rest%%/*}"
  else
    # ~/Library/Caches/<something>
    if [[ "$p" == "$HOME/Library/Caches/"* ]]; then
      local rest
      rest="${p#"$HOME/Library/Caches/"}"
      owner_key="${rest%%/*}"
    fi
  fi

  if [[ -n "$owner_key" ]]; then
    # If key contains path separators, ignore
    if [[ "$owner_key" == *"/"* ]]; then
      owner_key=""
    fi
  fi

  # Normalize common bundle-id variants so we can match inventory keys.
  # Examples:
  #   EQHXZ8M8AV.group.com.google.drivefs -> com.google.drivefs
  #   group.net.whatsapp.WhatsApp.shared -> net.whatsapp.WhatsApp.shared
  #   6N38VWS5BX.ru.keepcoder.Telegram -> ru.keepcoder.Telegram
  local owner_key_norm1=""
  local owner_key_norm2=""
  if [[ -n "$owner_key" ]]; then
    # Strip Team ID prefix if present (10 chars + dot)
    if [[ "$owner_key" =~ ^[A-Z0-9]{10}\.(.+)$ ]]; then
      owner_key_norm1="${BASH_REMATCH[1]}"
    fi
    # Strip leading group.
    if [[ "$owner_key" == group.* ]]; then
      owner_key_norm2="${owner_key#group.}"
    elif [[ -n "$owner_key_norm1" && "$owner_key_norm1" == group.* ]]; then
      owner_key_norm2="${owner_key_norm1#group.}"
    fi
  fi

  # 2) If not found, infer app from /Applications/<Name>.app
  if [[ -z "$owner_key" && "$p" == /Applications/*".app"* ]]; then
    local app_base after
    after="${p#/Applications/}"
    app_base="${after%%/*}"
    owner_key="$(_inventory_normalize_app_key "$app_base")"
  fi

  if [[ -n "$owner_key" ]]; then
    local hit

    # Try exact key first.
    if hit="$(inventory_lookup "$owner_key" 2>/dev/null)"; then
      local hit_name hit_source hit_path
      IFS=$'\t' read -r hit_name hit_source hit_path <<< "$hit"
      owner_name="$hit_name"
      owner_source="$hit_source"
      installed="true"
    # Then try normalized variants.
    elif [[ -n "$owner_key_norm1" ]] && hit="$(inventory_lookup "$owner_key_norm1" 2>/dev/null)"; then
      local hit_name hit_source hit_path
      IFS=$'\t' read -r hit_name hit_source hit_path <<< "$hit"
      owner_name="$hit_name"
      owner_key="$owner_key_norm1"
      owner_source="$hit_source"
      installed="true"
    elif [[ -n "$owner_key_norm2" ]] && hit="$(inventory_lookup "$owner_key_norm2" 2>/dev/null)"; then
      local hit_name hit_source hit_path
      IFS=$'\t' read -r hit_name hit_source hit_path <<< "$hit"
      owner_name="$hit_name"
      owner_key="$owner_key_norm2"
      owner_source="$hit_source"
      installed="true"
    else
      # If it looks like a bundle id, report it (sanitized/capped for display).
      local display
      display="$(_inventory_sanitize_tsv "$owner_key")"
      if [[ ${#display} -gt 120 ]]; then
        display="${display:0:117}..."
      fi
      owner_name="$display"
      owner_source="unknown"
      installed="false"
    fi
  fi

  echo "${owner_name}|${owner_key}|${owner_source}|${installed}"
}

run_inventory_module() {
  # Contract:
  #   run_inventory_module <mode> <apply> <backup_dir>
  local mode="$1"
  local apply="$2"
  local backup_dir="$3"

  # Inputs
  _inventory_log "Inventory: mode=${mode} apply=${apply} backup_dir=${backup_dir} (inspection-only; apply ignored)"

  # Inventory is always inspection-only.
  _inventory_debug "mode=${mode} apply=${apply} backup=${backup_dir}"

  inventory_build

  # Summary collector integration (best-effort)
  if command -v summary_set >/dev/null 2>&1; then
    local inv_items
    inv_items="$(awk 'END{print NR+0}' "$INVENTORY_FILE" 2>/dev/null || echo 0)"
    summary_set "inventory" "ready" "$INVENTORY_READY"
    summary_set "inventory" "items" "$inv_items"
    summary_set "inventory" "brew_bins_ready" "${INVENTORY_BREW_BINS_READY}"
  fi
}