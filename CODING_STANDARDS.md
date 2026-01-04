# Comment Formatting Rules

This document defines how comments should be written in mc-leaner code.

The goal is **clarity, consistency, and auditability**.

---

## General principles

- Comments explain **intent**, not obvious mechanics
- Safety-related logic must always be commented
- Prefer fewer, clearer comments over dense blocks

---

## File headers

Every script file must start with a short header:

```bash
# mc-leaner: <short description>
# Purpose: <what this file is responsible for>
# Safety: <any safety-sensitive behavior>
```

Example:

```bash
# mc-leaner: launchd module
# Purpose: Detect and safely relocate orphaned LaunchAgents and LaunchDaemons
# Safety: Skips security software and homebrew-managed services
```

---

## Section headers

Use clear section dividers:

```bash
# ----------------------------
# Launchd scan
# ----------------------------
```

Rules:
- Use dashed separators
- Title case
- One blank line before and after

---

## Inline comments

Use inline comments sparingly and only when logic is non-obvious.

Good:

```bash
# Skip active services to avoid breaking running processes
if is_active_job "$label"; then
  continue
fi
```

Avoid:

```bash
# Check if label is active
if is_active_job "$label"; then
  continue
fi
```

---

## Safety-critical comments

Any logic that:

- skips protected items
- performs privilege escalation
- moves system files

**must** be commented.

Example:

```bash
# HARD SAFETY: never touch security or endpoint protection software
case "$label" in
  *malwarebytes*|*bitdefender*)
    continue
    ;;
esac
```

---

## TODOs and warnings

Use explicit prefixes:

```bash
# TODO: improve detection once launchctl APIs are more reliable
# WARNING: heuristic detection, may flag legitimate services
```

Avoid vague TODOs.

---

## Comment tone

- Neutral
- Technical
- No jokes or sarcasm
- No marketing language

Comments are part of the safety surface.

---

## Final rule

If a future contributor removes or alters safety logic, the comment explaining that logic must be updated as well.

Code without intent documentation is considered unsafe.

## Module Output Contract

Every module in mc-leaner must follow the same observable execution contract.

This contract is part of the tool’s safety and usability guarantees.

### Required phases

Each module must execute and log output in the following order:

1. **Inputs**
   - Clearly log what is being scanned (paths, scope, thresholds).
   - In `--explain` mode, explicitly state assumptions and limits.

2. **Inspection**
   - Perform read-only analysis by default.
   - No filesystem mutations unless `--apply` is explicitly set.

3. **Inline reasoning**
   - While scanning, log why items are:
     - flagged
     - skipped
     - protected
   - Reasons must be human-readable and deterministic.

4. **End-of-run summary**
   - At the end of the module, print a consolidated summary of:
     - all flagged items that may require user action
     - totals and counts (even if zero)
   - If no items are flagged, this must be stated explicitly.

### Enforcement

- Missing an end-of-run summary is a **bug**.
- Logging findings only inline without summarizing them at the end is not acceptable.
- Modules that do not follow this contract must be fixed before release.
