#!/bin/bash
# mc-leaner: safety rules
# Purpose: Centralize hard skip logic to reduce risk of disabling security tooling or managed services
# Safety: These rules are intentionally conservative; changes here are security-sensitive and must be reviewed carefully

# NOTE: This library avoids setting shell-global strict mode.
# The entrypoint (mc-leaner.sh) is responsible for `set -euo pipefail`.

# ----------------------------
# Protected labels
# ----------------------------

# HARD SAFETY: never touch security, endpoint protection, or EDR tooling
# WARNING: heuristic matching; may include false positives by design
# NOTE: non-exhaustive list (security surface changes must be reviewed)
is_protected_label() {
  local label="$1"
  local normalized
  normalized="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
  case "$normalized" in
    *malwarebytes*|*mbam*|*bitdefender*|*crowdstrike*|*sentinel*|*sophos*|*carbonblack*|*defender*|*endpoint*)
      return 0
      ;;
  esac
  return 1
}

# Purpose: Apply the protected-product rule to a filesystem path immediately
# before mutation. This is intentionally conservative and case-insensitive.
is_protected_path() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  is_protected_label "$path"
}

# System launchd definitions and logs are inspection-only. They can be active
# even when ownership or launchctl state cannot be resolved reliably.
is_report_only_system_path() {
  local path="$1"
  local physical_path="$path"
  local parent parent_real
  parent="$(dirname "$path")"
  parent_real="$(cd "$parent" 2>/dev/null && pwd -P)" || parent_real=""
  if [[ -n "$parent_real" ]]; then
    physical_path="${parent_real}/$(basename "$path")"
  fi

  case "$path" in
    /Library/LaunchAgents|/Library/LaunchAgents/*|/Library/LaunchDaemons|/Library/LaunchDaemons/*|/Library/Logs|/Library/Logs/*|/var/log|/var/log/*|/private/var/log|/private/var/log/*)
      return 0
      ;;
  esac
  case "$physical_path" in
    /Library/LaunchAgents|/Library/LaunchAgents/*|/Library/LaunchDaemons|/Library/LaunchDaemons/*|/Library/Logs|/Library/Logs/*|/var/log|/var/log/*|/private/var/log|/private/var/log/*)
      return 0
      ;;
  esac
  return 1
}

# ----------------------------
# Homebrew-managed services
# ----------------------------

# Purpose: Identify Homebrew-managed launchd labels.
# Safety: These are managed via Homebrew; modules should skip or treat as owned by Homebrew.
is_homebrew_service_label() {
  local label="$1"
  [[ "$label" == homebrew.mxcl.* ]]
}

# End of library
