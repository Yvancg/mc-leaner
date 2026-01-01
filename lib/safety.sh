#!/bin/bash
set -euo pipefail

# HARD SAFETY: skip security/endpoint tools always
is_protected_label() {
  local label="$1"
  case "$label" in
    *malwarebytes*|*mbam*|*bitdefender*|*crowdstrike*|*sentinel*|*sophos*|*carbonblack*|*defender*|*endpoint*)
      return 0
      ;;
  esac
  return 1
}

# Default skip: Homebrew services
is_homebrew_service_label() {
  local label="$1"
  [[ "$label" == homebrew.mxcl.* ]]
}
