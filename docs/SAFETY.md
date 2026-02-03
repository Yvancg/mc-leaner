# SAFETY

This document explains the safety guarantees, assumptions, and limits of **mc-leaner**.

mc-leaner is a maintenance tool. It is intentionally conservative. Since v1.6.0, mc-leaner relies on a centralized inventory of installed software to reduce guesswork and false positives.

---

## Core safety guarantees

mc-leaner guarantees the following:

### 1. Safe by default

- The default mode is **dry-run**
- No files are moved unless `--apply` is explicitly used
  - `--apply` must be provided on the CLI (config files cannot enable it)

### 2. No deletion

- mc-leaner never deletes files
- All cleanup actions move files to a timestamped backup folder

### 3. Reversible actions

- Every moved file can be restored manually
- Built-in restore helpers are available via `--list-backups` and `--restore-backup`
- Restore uses a checksum-validated manifest to detect tampering
- A reboot restores normal launchd behavior once files are restored

### 4. Explicit user consent

- Each potentially destructive action requires confirmation
- No batch or silent cleanup

### 5. Inventory-first decisions

- Cleanup decisions are based on a shared inventory of installed apps, bundle IDs, and package managers
- Modules do not independently guess ownership when reliable inventory data exists
- Heuristics are used only as a fallback

---

## Protected categories (hard skips)

Items positively identified in the inventory as system-owned or actively installed are never flagged as leftovers.

The following categories are **never touched** by mc-leaner:

### Security and endpoint protection

Examples include (non-exhaustive):

- Bitdefender
- Malwarebytes
- CrowdStrike
- Sophos
- SentinelOne
- Carbon Black
- Microsoft Defender

These services may not have visible app bundles and removing them can break system security.

### Homebrew-managed services

- Launchd labels matching `homebrew.mxcl.*` are skipped by default
- These services should be managed via Homebrew, not manually

---

## Heuristics and limitations

mc-leaner prefers inventory-backed knowledge and falls back to heuristics only when ownership cannot be determined.

### Launchd detection

A launchd plist may be flagged as orphaned if:

- it is not currently loaded
- its label does not match known installed apps
- it is not explicitly protected

False positives are rare when inventory data is available. Flagging never implies removal is recommended.

### Binary inspection

Checks in `/usr/local/bin` are heuristic:

- manually installed tools may be flagged
- Homebrew and package inventory data are used when available to improve accuracy

### Inventory limitations

- The inventory reflects the current system state at scan time
- Manually removed or partially uninstalled software may still leave artifacts
- Inventory data improves accuracy but does not guarantee completeness

### Intel-only reporting

The Intel-only executable report:

- is informational only
- includes executables inside app bundles
- should not be used to delete files blindly

---

## Failure modes and recovery

### Something stopped working

1. Restore the affected files from the backup folder
   - Use `bash mc-leaner.sh --list-backups`
   - Then `bash mc-leaner.sh --restore-backup <backup_dir>`
2. Move them back to their original locations
3. Reboot

### Launch service does not restart

- Verify correct file ownership and permissions
- Reboot again
- If needed, reinstall the affected application

---

## What mc-leaner will never do

mc-leaner will never:

- delete files automatically
- modify application bundles
- install background services
- run on a schedule
- hide actions from the user

---

## User responsibility

mc-leaner is intentionally transparent.

You are expected to:

- read prompts carefully
- understand what you approve
- restore files if unsure

If you are not comfortable inspecting system files, do not use `--apply`.

---

## Summary

mc-leaner is designed to reduce risk, not eliminate it.

The safest cleanup is the one you understand.
