# Changelog

All notable changes to this project are documented in this file.

This project follows a pragmatic versioning scheme:

- MAJOR.MINOR.PATCH
- v1.0.x is maintenance and bugfix-only
- New features land in minor releases (v1.1, v1.2, …)

---

## v2.4.0 — Output, restore safety, and configurability

**Release date:** 2026-02-03

### Added

- JSON output to file (`--json-file`)
- Report export (`--export`)
- Backup management (`--list-backups`, `--restore-backup`)
- Progress indicator (`--progress`)
- Config file support (`~/.mcleanerrc`)

### Changed

- Thresholds are configurable for caches, logs, leftovers, and disk
- Startup items include per-item impact seconds (`impact_s`)

### Fixed

- Backup restore now validates manifest checksum
- Backup manifest entries are safely encoded to avoid parsing issues
- Config file can no longer enable `--apply` without explicit CLI flag

# ## v2.3.0 — Summary normalization, move contract unification, and safer attribution

**Release date:** 2026-02-02

### Added

- Shared helper utilities
  - Centralized temp file creation/cleanup and path redaction helpers
  - Inventory-backed owner lookup helper for consistent attribution
- Background service visibility records
  - `SERVICE?` records for correlation
  - network-facing classification (explicit, conservative heuristics)
- Startup system scan opt-in (`--startup-system`)
  - default startup scan is user scope only

### Changed

- Run summary formatting
  - Normalized module summary lines to `module key=value` format
  - Reduced duplicate summary lines from the orchestrator

- Move handling
  - All move-capable modules now use the shared `move_attempt` contract
  - Consistent failure classification and messaging

- Disk ownership attribution
  - Inventory-first matching with conservative heuristics when inventory is missing
- Inventory index path redaction
  - Consistent basename-only display under `--explain`, redacted otherwise
- Launchd summary clarity
  - `plists_checked` surfaced alongside flagged counts
- Timing stability
  - Per-module durations survive RETURN traps under strict shell

### Fixed

- Argument alignment for the bins module in the CLI dispatcher
- Owner attribution output sanitization (tab/newline escape safety)

# ## v2.2.0 — Startup impact analysis, timing fixes, and module contract alignment

**Release date:** 2026-01-27

### Added

- Startup impact scoring
  - Classifies flagged startup items by estimated impact (low, medium, high)
  - Surfaces an overall startup risk signal in the run summary

- Consistent module contracts
  - Caches module now accepts `--explain` and inventory index arguments like other inspection modules
  - All flag-capable modules export newline-delimited `*_FLAGGED_IDS_LIST` consistently

### Changed

- Run summary
  - Deterministic ordering and formatting across all modules
  - Improved timing attribution per module and total runtime

### Fixed

- Timing arithmetic errors under strict shell settings
- Argument mismatches between CLI dispatcher and module entrypoints

## v2.1.0 — Disk inspection, flagged IDs export and run summary improvements

**Release date:** 2026-01-26

### Added

- Disk inspection module
  - Adds a system lens for large disk consumers with inventory-backed owner attribution
  - Flags paths above the configured threshold and summarizes total flagged size

- Flagged item identifier exports
  - Flag-capable modules now export newline-delimited *_FLAGGED_IDS_LIST variables (startup, launchd, caches, logs, leftovers, disk).
  - Enables consistent, structured reporting of *what* was flagged, not just counts

- Clean, multi-line run summary output

### Changed

- Run summary now includes flagged counts and sizes per module
- Improved output formatting for better readability in terminal and logs

### Fixed

- Edge cases in flagged ID exports causing empty lines
- Run summary misalignment on narrow terminals

---

## v2.0.0 — Contracted core, startup inspection & system lenses

**Release date:** 2026-01-24

This release locks the module contract and output format for the v2 series.  
All inspections now rely on a shared, explicit inventory layer and follow a consistent, explainable decision model.

### Added

- Startup inspection module
  - Inspects LaunchDaemons, LaunchAgents, and Login Items
  - Classifies startup scope (boot vs login), source, owner, and execution path
  - Flags unknown or non-inventory-backed startup entries
  - Inspection-first design with no destructive actions

- Inventory-driven system lenses
  - Startup, caches, bins, launchd, leftovers, and intel modules now rely on inventory as the single source of truth
  - Eliminates heuristic-only ownership detection and cross-module duplication

### Changed

- Module contract (v2)
  - Standardized entrypoint naming (`run_<module>_module`)
  - Unified logging, explain output, and run summary semantics
  - Clear separation between discovery (inventory) and inspection logic

- Orchestration
  - Deterministic module ordering
  - Explicit module availability checks with graceful degradation
  - Predictable behavior across `scan`, `clean`, and module-specific modes

### Improved

- Startup analysis
  - Clearer owner attribution (Apple, user, third-party, unknown)
  - Reduced false positives for system-managed services
  - Explain output shows why an item is considered safe, unknown, or skipped

- Safety and resilience
  - Hardened strict-shell behavior across all modules
  - No silent failures under `set -u`
  - Consistent non-destructive guarantees across inspection modules

### Stability

- Full-system scan and clean passes without runtime errors
- Explain-mode coverage for all inspection decisions
- Locked output format suitable for scripting and long-term support

---

## v1.6.0 — Inventory core & system-wide hardening

**Release date:** 2026-01-08

### Added

- Inventory core module
  - Centralized discovery of installed applications, bundle identifiers, and executable roots
  - Shared inventory used consistently by caches, leftovers, bins, launchd, and intel modules
  - Lazy, on-demand population to reduce startup cost and unnecessary scans
  - Explicit readiness checks to prevent partial or inconsistent state usage

### Fixed

- Unbound variable and array edge cases across modules under strict shell settings
- Incorrect cache ownership reporting for Chromium-based applications
- Inventory-dependent race conditions during explain-mode scans
- Silent skips caused by missing or partially initialized shared state

### Improved

- Caches module
  - Accurate owner attribution using inventory data (e.g. Google Chrome, WhatsApp)
  - Correct handling of nested container caches and Apple-owned cache paths
  - Reduced false positives and duplicate reporting
  - Explain-mode now shows stable, user-meaningful ownership and decision paths

- Leftovers module
  - Stronger installed-app matching via inventory instead of heuristic-only name checks
  - Improved handling of group containers and bundle-id prefixes
  - Clearer explain output for skip reasons (installed, protected, below threshold)

- Intel-only executable scan
  - Stable root discovery via inventory-provided application paths
  - Deduplicated scan roots and hardened array handling under `set -u`
  - More accurate top-source aggregation

- Orchestration and module boundaries
  - Clear separation between inventory building and per-module inspection logic
  - Reduced cross-module coupling and implicit dependencies
  - More predictable execution order and explain output

### Stability

- Full end-to-end scan passes with `--explain` and strict error checking
- No runtime errors across all modules in full system scans
- Consistent run summary reporting across general and module-specific modes

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
