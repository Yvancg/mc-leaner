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

# Purpose: Identify Homebrew-managed launchd labels.
# Safety: These are managed via Homebrew; modules should skip or treat as owned by Homebrew.
is_homebrew_service_label() {
  local label="$1"
  [[ "$label" == homebrew.mxcl.* ]]
}

# End of library
