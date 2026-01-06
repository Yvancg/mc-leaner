

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
    # Fallback: read Info.plist
    local plist="$app_path/Contents/Info.plist"
    if [[ -f "$plist" ]]; then
      bid="$(/usr/bin/defaults read "$plist" CFBundleIdentifier 2>/dev/null || true)"
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

  # Use find with -maxdepth 1 to avoid heavy recursion. Many apps live at root.
  # We still allow nested .app inside /Applications via other modules; inventory
  # is for ownership resolution.
  local app
  while IFS= read -r -d '' app; do
    local base name bid
    base="$(basename "$app")"
    name="${base%.app}"
    bid="$(_inventory_bundle_id_for_app "$app")"

    _inventory_add_row "app" "$source" "$name" "$bid" "$app" ""

    # Index keys
    if [[ -n "$bid" ]]; then
      _inventory_add_index "$bid" "$name" "$source" "$app"
    fi
    _inventory_add_index "$(_inventory_normalize_app_key "$base")" "$name" "$source" "$app"
    _inventory_add_index "$(_inventory_normalize_app_key "$name")" "$name" "$source" "$app"
  done < <(find "$root" -maxdepth 1 -type d -name "*.app" -print0 2>/dev/null)
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
    _inventory_add_index "$f" "$f" "brew" ""
  done < <(brew list --formula 2>/dev/null || true)

  local c
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    _inventory_add_row "brew_cask" "brew" "$c" "" "" "$c"
    _inventory_add_index "brew:cask:$c" "$c" "brew" ""
    _inventory_add_index "$c" "$c" "brew" ""
  done < <(brew list --cask 2>/dev/null || true)
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

  # Truncate
  : > "$INVENTORY_FILE"
  : > "$INVENTORY_INDEX_FILE"

  _inventory_log "Inventory: building installed software list (apps + Homebrew)..."

  # App roots
  _inventory_scan_apps_root "/System/Applications" "system"
  _inventory_scan_apps_root "/Applications" "user"
  _inventory_scan_apps_root "$HOME/Applications" "user"

  # Homebrew
  _inventory_scan_brew

  # Summaries
  local apps_system apps_user brew_formula brew_cask
  apps_system="$(awk -F'\t' '$1=="app" && $2=="system" {c++} END{print c+0}' "$INVENTORY_FILE" 2>/dev/null || echo 0)"
  apps_user="$(awk -F'\t' '$1=="app" && $2=="user" {c++} END{print c+0}' "$INVENTORY_FILE" 2>/dev/null || echo 0)"
  brew_formula="$(awk -F'\t' '$1=="brew_formula" {c++} END{print c+0}' "$INVENTORY_FILE" 2>/dev/null || echo 0)"
  brew_cask="$(awk -F'\t' '$1=="brew_cask" {c++} END{print c+0}' "$INVENTORY_FILE" 2>/dev/null || echo 0)"

  _inventory_log "Inventory: apps system=$apps_system user=$apps_user; brew formulae=$brew_formula casks=$brew_cask"

  INVENTORY_READY="true"
  export INVENTORY_FILE INVENTORY_INDEX_FILE INVENTORY_READY
  return 0
}

inventory_lookup() {
  # Public: lookup by key in index.
  # Usage: inventory_lookup "com.apple.Safari"
  # Output: name\tsource\tapp_path (empty if not found)
  local key="$1"
  if [[ "${INVENTORY_READY}" != "true" || -z "${INVENTORY_INDEX_FILE}" || ! -f "${INVENTORY_INDEX_FILE}" ]]; then
    return 1
  fi

  awk -F'\t' -v k="$key" '$1==k {print $2"\t"$3"\t"$4; found=1; exit} END{exit(found?0:1)}' "$INVENTORY_INDEX_FILE" 2>/dev/null
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
    owner_key="$(printf '%s' "$p" | awk -F'/Library/Containers/' '{print $2}' | awk -F'/' '{print $1}')"
  elif [[ "$p" == *"/Library/Group Containers/"* ]]; then
    owner_key="$(printf '%s' "$p" | awk -F'/Library/Group Containers/' '{print $2}' | awk -F'/' '{print $1}')"
  else
    # ~/Library/Caches/<something>
    if [[ "$p" == "$HOME/Library/Caches/"* ]]; then
      owner_key="$(printf '%s' "$p" | awk -F"$HOME/Library/Caches/" '{print $2}' | awk -F'/' '{print $1}')"
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
    local app_base
    app_base="$(printf '%s' "$p" | awk -F'/Applications/' '{print $2}' | awk -F'/' '{print $1}')"
    owner_key="$(_inventory_normalize_app_key "$app_base")"
  fi

  if [[ -n "$owner_key" ]]; then
    local hit
    if hit="$(inventory_lookup "$owner_key" 2>/dev/null)"; then
      owner_name="$(printf '%s' "$hit" | awk -F'\t' '{print $1}')"
      owner_source="$(printf '%s' "$hit" | awk -F'\t' '{print $2}')"
      installed="true"
    else
      # If it looks like a bundle id, report it.
      owner_name="$owner_key"
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
    inv_items="$(wc -l < "$INVENTORY_FILE" 2>/dev/null || echo 0)"
    summary_set "inventory" "ready" "$INVENTORY_READY"
    summary_set "inventory" "items" "$inv_items"
  fi
}