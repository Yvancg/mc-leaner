# Changelog

All notable changes to this project are documented in this file.

This project follows a pragmatic versioning scheme:

- MAJOR.MINOR.PATCH
- v1.0.x is maintenance and bugfix-only
- New features land in minor releases (v1.1, v1.2, …)

---

## 1.5.0 - Permissions inspection

**Release date:** 2026-01-06

### Added

- Permissions inspection module
  - Detects execution context and permission constraints
  - Explains skipped actions due to interactivity, GUI availability, or restricted paths
  - Integrated into scan and standalone permissions-only mode

### Fixed

- Intel-only executable reporting:
  - Corrected counting logic
  - Stabilized preview output
  - Added top-source summaries
  - Hardened report pipeline

### Improved

- Standardized Logs and Caches summary output
- Clarified Homebrew inspection-only messaging

## v1.4.0 — Leftovers inspection & cleanup menu

**Release date:** 2026-01-05

### Added

- Leftovers inspection module (user-level support data)
  - Scans Application Support, Containers, Group Containers, Preferences, and Saved Application State
  - Flags orphaned app data based on bundle-id matching and installed app inventory
  - Size threshold default: 50MB
  - Interactive cleanup menu when running with `--apply`
  - All moves are reversible via timestamped backup directories

### Improved

- Unified safe move contract across all modules (bins, launchd, caches, logs, brew, leftovers, intel)
- Consistent end-of-run summary across all modes
- Clear distinction between:
  - user-declined actions
  - non-interactive skips
  - permission or filesystem failures
- Explain-mode output now consistently reports skip reasons and decision paths

### Fixed

- Incorrect “user declined” messages when no prompt was shown
- Silent failures when moving protected or permission-restricted paths
- Bash 3.2 edge cases with unbound arrays under `set -u`

## v1.3.0 — Homebrew hygiene (inspection-only)

**Release date:** 2026-01-04

### Added

- Homebrew hygiene module (skeleton)
  - Initial `brew.sh` module scaffold
  - CLI wiring for `--mode brew-only`
  - Inspection-first design (no cleanup logic yet)

## v1.2.0 — Log inspection module

**Release date:** 2026-01-03

### Added

- Log inspection module (inspection-first)
  - Scans `~/Library/Logs`, `/Library/Logs`, and `/var/log`
  - Flags log files and directories ≥ 50MB
  - Groups related logs and rotation siblings
  - Reports size, last modified time, and owning subsystem (best-effort)
  - `--explain` mode for rotation context and top subfolders
  - Optional cleanup via relocation only (user-confirmed, reversible)

### Improved

- Unified inspection output format across caches and logs
- Explain-mode consistency across all modules

### Fixed

- Edge cases where rotated logs were double-counted
- Inconsistent grouping of subsystem-owned log directories

## v1.1.0 — Cache inspection module

**Release date:** 2026-01-02

### Added

- User-level cache inspection module (inspection-first)
  - Groups caches by owning app
  - Reports size and last modified time
  - `--explain` mode showing top subfolders by size

### Improved

- Hardened safety rules for security and endpoint software
- Reduced false positives for Zoom, Google Updater, and Homebrew-managed components
- Lazy inventory building for better performance and clarity
- Consistent logging format across all modules
- Clear dry-run vs apply behavior across all modes

### Fixed

- Incorrect orphan detection for valid launchd programs
- Symlink handling in `/usr/local/bin`
- Mode dispatch edge cases
- Explain-mode propagation across modules

---

## v1.0.0 — Initial stable release

**Release date:** 2026-01-01

### Added

- Launchd inspection module for LaunchAgents and LaunchDaemons
- `/usr/local/bin` inspection module with conservative orphan heuristics
- Intel-only executable reporting (`--mode report`)
- Reversible backup mechanism (move-only, no deletions)
