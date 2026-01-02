# Changelog

All notable changes to this project are documented in this file.

This project follows a pragmatic versioning scheme:

- MAJOR.MINOR.PATCH
- v1.0.x is bugfix-only
- New features land in v1.1+

---

## v1.1.0 — Cache inspection module and reliability improvements

**Release date:** 2026-01-02

### Added

- Launchd inspection module for LaunchAgents and LaunchDaemons
- `/usr/local/bin` inspection module with conservative orphan heuristics
- User-level cache inspection module (inspection-first)
  - Groups caches by owning app
  - Reports size and last modified time
  - `--explain` mode showing top subfolders by size
- Intel-only executable reporting (`--mode report`)
- `--explain` flag across modules to clarify decisions
- Reversible backup mechanism (move-only, no deletions)

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
