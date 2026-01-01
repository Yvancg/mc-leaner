#!/bin/bash
# mc-leaner: Safe, interactive macOS cleaner (v1: launchd orphan finder + /usr/local/bin checks + intel report)
# Requirements: bash (3.2+), osascript (optional for GUI), launchctl
# Optional: brew (improves orphan detection)

set -euo pipefail

# ----------------------------
# Defaults (safe-by-default)
# ----------------------------
MODE="all"          # all | launchd | bins | intel
APPLY=0             # 0 = dry-run, 1 = move items
GUI=1               # 1 = osascript dialog, 0 = terminal prompt
BACKUP_ROOT="$HOME/Desktop"
BACKUP_DIR="$BACKUP_ROOT/Orphaned_Backups_$(date +%Y%m%d_%H%M%S)"

# ----------------------------
# Args
# ----------------------------
usage() {
  cat <<'EOF'
Usage:
  bash mc-leaner.sh [--all|--launchd|--bins|--intel] [--dry-run|--apply] [--gui|--no-gui]

Defaults:
  --all --dry-run --gui

Examples:
  bash mc-leaner.sh --launchd --dry-run
  bash mc-leaner.sh --launchd --apply
  bash mc-leaner.sh --all --apply --no-gui
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --all) MODE="all";;
    --launchd) MODE="launchd";;
    --bins) MODE="bins";;
    --intel) MODE="intel";;
    --dry-run) APPLY=0;;
    --apply) APPLY=1;;
    --gui) GUI=1;;
    --no-gui) GUI=0;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
  shift
done

mkdir -p "$BACKUP_DIR"

# ----------------------------
# Helpers
# ----------------------------
log() { printf "%s\n" "$*"; }

ask_term() {
  # Returns 0 if yes, 1 if no
  printf "Move to backup? %s [y/N]: " "$1"
  read -r ans
  [[ "${ans:-}" == "y" || "${ans:-}" == "Y" ]]
}

ask_gui() {
  # Returns 0 if user clicked Move, 1 otherwise
  # If osascript fails, fall back to terminal prompt
  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'display dialog "Orphaned file detected:\n'"$1"'\n\nMove to backup folder?\n\nBackup:\n'"$BACKUP_DIR"'" buttons {"Cancel", "Move"} default button 2' \
      2>/dev/null | grep -q "Move" && return 0
    return 1
  fi
  ask_term "$1"
}

confirm_move() {
  local path="$1"
  if [[ "$GUI" -eq 1 ]]; then
    ask_gui "$path"
  else
    ask_term "$path"
  fi
}

needs_sudo() {
  # Anything under /Library or /System typically needs sudo
  case "$1" in
    /Library/*|/System/*) return 0;;
    *) return 1;;
  esac
}

safe_mv() {
  local src="$1"
  local dst_dir="$2"

  if [[ "$APPLY" -eq 0 ]]; then
    log "DRY-RUN: would move $src -> $dst_dir/"
    return 0
  fi

  if needs_sudo "$src"; then
    sudo mv "$src" "$dst_dir/"
  else
    mv "$src" "$dst_dir/"
  fi
  log "Moved: $src -> $dst_dir/"
}

# Hard safety labels: never touch these via the tool
is_security_label() {
  local label="$1"
  case "$label" in
    *malwarebytes*|*mbam*|*bitdefender*|*crowdstrike*|*sentinel*|*sophos*|*carbonblack*|*defender*|*endpoint*)
      return 0
      ;;
  esac
  return 1
}

# Skip homebrew-managed services
is_homebrew_service_label() {
  local label="$1"
  case "$label" in
    homebrew.mxcl.*) return 0;;
  esac
  return 1
}

# ----------------------------
# Build "known apps" lists
# ----------------------------
build_known_lists() {
  log "Scanning installed apps in /Applications and ~/Applications..."
  : > /tmp/installed_apps.txt
  find /Applications -maxdepth 2 -type d -name "*.app" >> /tmp/installed_apps.txt 2>/dev/null || true
  find "$HOME/Applications" -maxdepth 2 -type d -name "*.app" >> /tmp/installed_apps.txt 2>/dev/null || true

  log "Listing Homebrew formulae and casks (if Homebrew is installed)..."
  : > /tmp/brew_formulae.txt
  if command -v brew >/dev/null 2>&1; then
    brew list --formula >> /tmp/brew_formulae.txt 2>/dev/null || true
    brew list --cask    >> /tmp/brew_formulae.txt 2>/dev/null || true
  else
    log "Homebrew not found, skipping brew based checks."
  fi

  cat /tmp/installed_apps.txt /tmp/brew_formulae.txt > /tmp/all_known_apps.txt
}

# ----------------------------
# launchd scan
# ----------------------------
scan_launchd() {
  build_known_lists

  log "Scanning active launchctl jobs..."
  active_jobs=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && active_jobs+=("$line")
  done < <(launchctl list | awk 'NR>1 {print $3}' | grep -v '^-$' || true)

  is_active_job() {
    local job="$1"
    local aj
    for aj in "${active_jobs[@]}"; do
      [[ "$aj" == "$job" ]] && return 0
    done
    return 1
  }

  log "Checking LaunchAgents and LaunchDaemons..."
  local plist_path label

  for plist_path in \
    /Library/LaunchAgents/*.plist \
    /Library/LaunchDaemons/*.plist \
    "$HOME/Library/LaunchAgents"/*.plist
  do
    [[ -f "$plist_path" ]] || continue

    label=$(defaults read "$plist_path" Label 2>/dev/null || echo "")
    [[ -z "$label" ]] && continue

    # HARD SAFETY
    if is_security_label "$label"; then
      log "SKIP (security): $plist_path"
      continue
    fi

    # Skip Homebrew-managed services
    if is_homebrew_service_label "$label"; then
      log "SKIP (homebrew service): $plist_path"
      continue
    fi

    # Skip if loaded in launchctl
    if is_active_job "$label"; then
      continue
    fi

    # Skip if label matches installed apps / brew list (heuristic)
    if grep -qF "$label" /tmp/all_known_apps.txt 2>/dev/null; then
      continue
    fi

    log "Orphaned launch item detected: $plist_path"
    if confirm_move "$plist_path"; then
      # Best effort: unload before moving
      if [[ "$plist_path" == /Library/LaunchDaemons/* ]]; then
        sudo launchctl bootout system "$plist_path" 2>/dev/null || true
      elif [[ "$plist_path" == /Library/LaunchAgents/* ]]; then
        sudo launchctl bootout system "$plist_path" 2>/dev/null || true
      else
        launchctl bootout "gui/$(id -u)" "$plist_path" 2>/dev/null || true
      fi
      safe_mv "$plist_path" "$BACKUP_DIR"
    fi
  done
}

# ----------------------------
# /usr/local/bin scan (Intel-era leftovers)
# ----------------------------
scan_usr_local_bin() {
  build_known_lists

  log "Checking /usr/local/bin for orphaned binaries (typical Intel leftovers)..."
  local bin_path base_bin

  for bin_path in /usr/local/bin/*; do
    [[ -x "$bin_path" ]] || continue
    base_bin="$(basename "$bin_path")"

    # If brew exists, only flag binaries not present in brew list (heuristic)
    if command -v brew >/dev/null 2>&1; then
      if ! grep -qF "$base_bin" /tmp/brew_formulae.txt 2>/dev/null; then
        log "Orphaned binary detected: $bin_path"
        if confirm_move "$bin_path"; then
          safe_mv "$bin_path" "$BACKUP_DIR"
        fi
      fi
    else
      # Without brew, do not auto-flag aggressively
      log "Homebrew not installed; skipping /usr/local/bin orphan detection to avoid false positives."
      break
    fi
  done
}

# ----------------------------
# Intel-only report
# ----------------------------
intel_report() {
  log "Scanning for Intel-only executables (this may take a while)..."
  local out="$HOME/Desktop/intel_binaries.txt"
  # Note: -perm +111 is deprecated in some find versions; keep it for macOS compatibility.
  find /Applications "$HOME/Applications" "$HOME/Library" /opt -type f -perm +111 -exec file {} + 2>/dev/null \
    | grep "Mach-O 64-bit executable x86_64" > "$out" || true
  log "Intel-only executables listed at: $out"
}

# ----------------------------
# Run selected mode
# ----------------------------
case "$MODE" in
  all)
    scan_launchd
    scan_usr_local_bin
    intel_report
    ;;
  launchd)
    scan_launchd
    ;;
  bins)
    scan_usr_local_bin
    ;;
  intel)
    intel_report
    ;;
esac

log "Done. Backup folder: $BACKUP_DIR"
if [[ "$APPLY" -eq 0 ]]; then
  log "Note: DRY-RUN mode. Re-run with --apply to actually move files."
fi
