#!/usr/bin/env bash
# mc-leaner: inventory module
# Purpose:
#   Build a canonical inventory of installed software (apps + Homebrew) so other
#   modules can map folders/files to an installed owner.
# Output:
#   - INVENTORY_FILE: TSV authoritative list
#   - INVENTORY_INDEX_FILE: TSV lookup index
#
# TSV columns (INVENTORY_FILE):
#   kind\tsource\tname\tbundle_id\tapp_path\tbrew_id
# TSV columns (INVENTORY_INDEX_FILE):
#   key\tname\tsource\tapp_path

set -uo pipefail

# These are exported for other modules.
INVENTORY_FILE=""
INVENTORY_INDEX_FILE=""
INVENTORY_READY="false"

# Optional in-memory cache for inventory lookups (only if bash supports associative arrays).
INVENTORY_CACHE_READY="false"
# Keys are inventory index keys; values are the full hit line: name\tsource\tapp_path

_inventory_log() {
  # shellcheck disable=SC2154
  log "$@"
}

_inventory_debug() {
  # shellcheck disable=SC2154
  if [[ "${EXPLAIN:-false}" == "true" ]]; then
    log "Inventory (explain): $*"
  fi
}

_inventory_tmpfile() {
  # Try mktemp with template first, fall back to simpler mktemp.
  local f=""
  f="$(mktemp -t mc-leaner_inventory.XXXXXX 2>/dev/null || true)"
  if [[ -z "$f" ]]; then
    f="$(mktemp 2>/dev/null || true)"
  fi
  echo "$f"
}

_inventory_sanitize_tsv() {
  # Replace tabs/newlines to keep TSV sane.
  local s="$1"
  s="${s//$'\t'/ }"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/ }"
  echo "$s"
}

_inventory_enable_cache_if_supported() {
  # macOS system bash is often 3.2 (no associative arrays). Only enable when supported.
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

_inventory_bundle_id_for_app() {
  # Best effort. Return empty string if unknown.
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

  if [[ -z "$key" ]]; then
    return 0
  fi

  printf '%s\t%s\t%s\t%s\n' "$key" "$name" "$source" "$app_path" >> "$INVENTORY_INDEX_FILE"
}

_inventory_normalize_app_key() {
  # Lowercase, strip spaces and common suffixes for a fuzzy-ish key.
  # This is intentionally conservative.
  local s="$1"
  s="${s%.app}"
  # lowercase
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
  # strip spaces
  s="${s// /}"
  echo "$s"
}

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

    # If the .app is a symlink, use its target to decide whether it is a system app.
    # This matters on newer macOS builds where some Apple apps appear under /Applications
    # but actually point into Cryptex or other system locations.
    target="$(/usr/bin/stat -f%Y "$app" 2>/dev/null || true)"
    if [[ -z "$target" ]]; then
      target="$app"
    fi

    effective_source="$source"
    if [[ "$target" == /System/Applications/* || "$target" == /System/Cryptexes/App/System/Applications/* ]]; then
      effective_source="system"
    fi

    bid="$(_inventory_bundle_id_for_app "$app")"

    _inventory_add_row "app" "$effective_source" "$name" "$bid" "$app" ""

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

  # 2) If not found, infer app from /Applications/<Name>.app
  if [[ -z "$owner_key" && "$p" == /Applications/*".app"* ]]; then
    local app_base after
    after="${p#/Applications/}"
    app_base="${after%%/*}"
    owner_key="$(_inventory_normalize_app_key "$app_base")"
  fi

  if [[ -n "$owner_key" ]]; then
    local hit
    if hit="$(inventory_lookup "$owner_key" 2>/dev/null)"; then
      local hit_name hit_source hit_path
      IFS=$'\t' read -r hit_name hit_source hit_path <<< "$hit"
      owner_name="$hit_name"
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
  # Entry point expected by mc-leaner.sh
  # Args: mode apply backup_dir
  local mode="$1"
  local apply="$2"
  local backup_dir="$3"

  # Inventory is always inspection-only.
  _inventory_debug "mode=$mode apply=$apply backup=$backup_dir"

  inventory_build

  # Summary collector integration (best-effort)
  if command -v summary_set >/dev/null 2>&1; then
    local inv_items
    inv_items="$(awk 'END{print NR+0}' "$INVENTORY_FILE" 2>/dev/null || echo 0)"
    summary_set "inventory" "ready" "$INVENTORY_READY"
    summary_set "inventory" "items" "$inv_items"
  fi
}