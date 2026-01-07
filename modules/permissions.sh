#!/bin/bash
# mc-leaner: permissions & environment diagnostics
# Purpose: explain why some paths cannot be inspected/moved (TCC, SIP, non-interactive shell)
# Safety: inspection-only; no file moves, no privilege escalation, no destructive operations

set -euo pipefail

# Expected globals (provided by entrypoint):
#   APPLY (true/false)
#   EXPLAIN (true/false)
#   BACKUP_DIR
# Utilities:
#   log, explain_log, is_cmd, summary_add

# ----------------------------
# Small helpers (local to module)
# ----------------------------
is_interactive() {
  # Purpose: determine whether we can safely prompt on stdin
  # Safety: inspection only
  [ -t 0 ] && [ -t 1 ]
}

detect_host_app() {
  # Purpose: best-effort identify the host app (Terminal, iTerm, VS Code)
  # Safety: inspection only
  # Note: PPID is often a shell (zsh/bash). We walk up the process tree to find the GUI host.

  if ! is_cmd ps; then
    echo "unknown"
    return 0
  fi

  local pid="${PPID:-}"
  local depth=0
  local comm=""
  local comm_base=""
  local ppid=""

  # Walk up a few levels to find the first recognizable GUI host.
  # Bash 3.2 safe loop.
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ $depth -lt 8 ]; do
    # `ps -o comm=` can return a full path that may include spaces (e.g. "/Applications/Visual Studio Code.app/..."),
    # so we must NOT split on whitespace.
    local comm_raw=""

    comm_raw="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
    comm="$(printf "%s" "$comm_raw" | sed 's/[[:space:]]*$//')"
    comm_base="$(basename "$comm" 2>/dev/null || printf "%s" "$comm")"

    # Match on both the raw command (may be a path) and the basename.
    case "$comm_base" in
      Terminal|Terminal.app)
        echo "Terminal"; return 0
        ;;
      iTerm2|iTerm2.app)
        echo "iTerm2"; return 0
        ;;
      Code|Code.app)
        echo "VS Code"; return 0
        ;;
      Electron)
        # Many Electron apps report `Electron`. Try to disambiguate via args when possible.
        local args=""
        args="$(ps -p "$pid" -o args= 2>/dev/null | tr -d '\n')"
        if printf "%s" "$args" | grep -qi "Visual Studio Code"; then
          echo "VS Code"; return 0
        fi
        ;;
    esac

    # Some hosts expose a full path in `comm` (including spaces). Catch common patterns.
    if printf "%s" "$comm" | grep -qi "Visual Studio Code\.app"; then
      echo "VS Code"; return 0
    fi
    if printf "%s" "$comm" | grep -qi "Terminal\.app"; then
      echo "Terminal"; return 0
    fi
    if printf "%s" "$comm" | grep -qi "iTerm\.app\|iTerm2\.app"; then
      echo "iTerm2"; return 0
    fi

    # Move to parent process
    ppid="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ' | tr -d '\n')"
    if [ -z "$ppid" ] || [ "$ppid" = "$pid" ]; then
      break
    fi

    pid="$ppid"
    depth=$((depth + 1))
  done

  # Fallback: report the immediate parent command (may be a shell path like /bin/zsh)
  if [ -n "$comm_base" ]; then
    case "$comm_base" in
      zsh|bash|sh|fish|/bin/zsh|/bin/bash|/bin/sh) echo "shell" ;;
      *) echo "$comm_base" ;;
    esac
  elif [ -n "$comm" ]; then
    # Last-resort: print the raw command string
    echo "$comm"
  else
    echo "unknown"
  fi
}

can_gui_prompt() {
  # Purpose: determine whether AppleScript prompts are possible
  # Safety: inspection only
  if ! is_cmd osascript; then
    return 1
  fi

  # A simple script that should succeed when a GUI session is available.
  # Note: this is best-effort; success does not guarantee prompt capability.
  osascript -e 'return 1' >/dev/null 2>&1
}

probe_listable() {
  # Usage: probe_listable "/path"
  # Returns:
  #   0 listable
  #   2 permission blocked (Operation not permitted)
  #   1 other failure
  local path="$1"
  local err=""

  if ls -1d "$path" >/dev/null 2>&1; then
    return 0
  fi

  err="$(ls -1d "$path" 2>&1 || true)"

  if printf "%s" "$err" | grep -qi "Operation not permitted"; then
    return 2
  fi

  return 1
}

print_fda_steps() {
  # Purpose: show short, actionable steps to grant Full Disk Access to the host app
  # Safety: logging only
  local host_app="$1"

  log "Permissions: likely blocked by macOS privacy controls (best-effort inference)."
  log "To allow inspection/moves in protected locations, grant Full Disk Access:"
  log "  1) System Settings → Privacy & Security → Full Disk Access"

  if [ "$host_app" = "VS Code" ]; then
    log "  2) Enable: Visual Studio Code"
    log "  3) If you run scripts via Terminal, enable: Terminal as well"
  elif [ "$host_app" = "Terminal" ] || [ "$host_app" = "iTerm2" ]; then
    log "  2) Enable: $host_app"
    log "  3) If you run scripts via VS Code, enable: Visual Studio Code as well"
  else
    log "  2) Enable the app you use to run mc-leaner (often Terminal or Visual Studio Code)"
  fi

  log "  4) Close and re-open the app, then re-run mc-leaner"
}

run_permissions_module() {
  # Purpose: run environment checks and print clear diagnostics
  # Safety: inspection only

  log "Permissions: scanning execution environment (inspection-only)..."

  local interactive="no"
  local host_app="unknown"
  local gui_prompt="no"
  local prompt_capable="no"

  if is_interactive; then
    interactive="yes"
  fi

  host_app="$(detect_host_app)"

  if can_gui_prompt; then
    gui_prompt="yes"
  fi

  # For mc-leaner, CLI prompting requires interactive stdin.
  if [ "$interactive" = "yes" ]; then
    prompt_capable="yes"
  fi

  explain_log "Permissions: interactive=$interactive"
  explain_log "Permissions: host_app=$host_app"
  explain_log "Permissions: gui_prompt=$gui_prompt"

  if [ "${APPLY:-false}" = "true" ] && [ "$prompt_capable" != "yes" ]; then
    log "Permissions: non-interactive run detected; prompts are disabled; some --apply moves may be skipped."
  fi

  # Probe key locations that frequently fail without Full Disk Access.
  # We do NOT claim FDA status; we infer likely blocks based on observed errors.
  local tcc_blocks=0
  local tcc_notes=()

  # User-level TCC sensitive locations
  local user_home="${HOME:-}" 
  if [ -n "$user_home" ]; then
    local p
    for p in \
      "$user_home/Library/Containers" \
      "$user_home/Library/Group Containers"; do

      if [ ! -d "$p" ]; then
        explain_log "Permissions: path missing (skip): $p"
        continue
      fi

      local rc=0
      if probe_listable "$p"; then
        rc=0
      else
        rc=$?
      fi

      if [ $rc -eq 2 ]; then
        tcc_blocks=$((tcc_blocks + 1))
        tcc_notes+=("$p")
        explain_log "Permissions: Operation not permitted (likely TCC block): $p"
      elif [ $rc -ne 0 ]; then
        explain_log "Permissions: could not access (non-fatal): $p"
      else
        explain_log "Permissions: accessible: $p"
      fi
    done
  fi

  # System locations that often require elevated privileges (SIP / permissions)
  # These probes are informational only.
  local sys_notes=()
  local sp
  for sp in \
    "/Library/LaunchDaemons" \
    "/Library/LaunchAgents" \
    "/Library/Logs" \
    "/var/log"; do

    if [ ! -d "$sp" ]; then
      explain_log "Permissions: path missing (skip): $sp"
      continue
    fi

    if probe_listable "$sp"; then
      explain_log "Permissions: accessible: $sp"
    else
      # Best-effort classification: treat "Operation not permitted" as a privacy/SIP style block.
      # We do not attempt privileged reads here.
      sys_notes+=("$sp (restricted)")
      explain_log "Permissions: restricted access: $sp"
    fi
  done

  if [ $tcc_blocks -gt 0 ]; then
    print_fda_steps "$host_app"
    log "Permissions: detected protected location access issues (inferred):"
    local n
    for n in "${tcc_notes[@]}"; do
      log "  - $n"
    done
  fi

  if [ "${EXPLAIN:-false}" = "true" ] && [ "${#sys_notes[@]}" -gt 0 ]; then
    log "Permissions (explain): system locations may require elevated privileges for moves:"
    local s
    for s in "${sys_notes[@]}"; do
      log "  - $s"
    done
  fi

  # Summary line (Module Output Contract)
  summary_add "permissions: interactive=$interactive host=$host_app gui_prompt=$gui_prompt tcc_blocks=$tcc_blocks"

  log "Permissions: inspection complete."
}

# ----------------------------
# Module contract
# ----------------------------
# Purpose: provide `run_permissions_module` for the entrypoint to call.
# Safety: do not auto-execute on source.
#
# The entrypoint (mc-leaner.sh) is responsible for calling:
#   run_permissions_module
#
# End of module.
