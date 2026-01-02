#!/bin/bash
# mc-leaner: safety rules
# Purpose: Centralize hard skip logic to reduce risk of disabling security tooling or managed services
# Safety: These rules are intentionally conservative; changes here are security-sensitive and must be reviewed carefully

set -euo pipefail

# ----------------------------
# Protected labels
# ----------------------------

# HARD SAFETY: never touch security or endpoint protection software
# NOTE: This list is heuristic and non-exhaustive by design
is_protected_label() {
  local label="$1"
  case "$label" in
    *malwarebytes*|*mbam*|*bitdefender*|*crowdstrike*|*sentinel*|*sophos*|*carbonblack*|*defender*|*endpoint*)
      return 0
      ;;
  esac
  return 1
}

# ----------------------------
# Homebrew-managed services
# ----------------------------

# Purpose: Identify Homebrew-managed launchd labels (users should manage these via Homebrew)
is_homebrew_service_label() {
  local label="$1"
  [[ "$label" == homebrew.mxcl.* ]]
}

# End of library
