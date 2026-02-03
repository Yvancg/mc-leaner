# mc-leaner Roadmap

This roadmap reflects the guiding philosophy of mc-leaner:

> **Visibility first. Cleanup second. Never silent.**

Dates are intentionally omitted. Features ship when they meet the safety bar.

---

## v1.0.x (maintenance)

Focus: **launchd hygiene and visibility**

- LaunchAgents / LaunchDaemons orphan detection
- Hard skip rules for security and endpoint software
- Intel-only executable reporting
- Conservative `/usr/local/bin` inspection
- Dry-run by default, reversible actions

Status: **stable foundation**

---

## v1.1.0 (released)

Focus: **inspection-first storage visibility**

### Implemented modules

#### Caches (inspection-first)

- List large user-level cache directories
- Show size, last modified, owning app
- Group by app with top subfolders
- Explain mode for detailed inspection
- Optional cleanup, user-level only, reversible

---

## v1.2.0 (released)

Focus: **inspection before cleanup**

### Implemented modules

#### Logs (inspection-first)

- Identify large or rapidly growing logs
- Group related logs and rotations
- Show size, last modified, owning subsystem
- Explain mode for rotation context and subfolders
- Optional cleanup via relocation only

---

## v1.3.0 (released)

Status: inspection-only Homebrew hygiene released

Focus: **inspection before cleanup**

### Implemented modules

#### Homebrew hygiene (inspection-only)

- Surface `brew doctor` issues
- Detect unlinked or outdated kegs
- Identify orphaned Homebrew services
- Suggest commands, do not execute automatically

---

## v1.4.0 (released)

Focus: **safe app residue inspection**

### Implemented modules

#### App leftovers (inspection-first)

- Detect app-related folders left behind after uninstall:
  - Containers
  - Group Containers
  - Application Support
  - Preferences
  - Saved Application State
- Correlate leftovers with installed app bundle IDs
- Hard skip rules for:
  - Apple / system-owned containers
  - Security and endpoint software
- Size threshold filtering (default 50MB)
- Explain mode showing why each item is skipped or flagged
- Optional relocation only:
  - User-confirmed
  - Reversible via backup directory
  - Shared safe move + error reporting contract

---

## v1.5.0 (released)

Focus: **execution context and permissions visibility**

### Implemented modules

#### Permissions (inspection-only)

- Detect execution context (interactive vs non-interactive)
- Identify host application (Terminal, VS Code, etc.)
- Detect GUI prompt availability
- Check accessibility of key paths (Containers, Group Containers, Logs, LaunchAgents/Daemons)
- Detect obvious TCC access blocks (best-effort)
- No permission changes, no prompts, no system mutations

---

## v1.6.0 (released)

Focus: **inventory-first architecture and cross-module accuracy**

### Implemented modules

#### Inventory (inspection-only, foundational)

- Build a unified inventory of installed software:
  - System apps
  - User apps
  - Homebrew formulae and casks
- Normalize names, bundle IDs, paths, and install sources
- Serve as a shared read-only index for other modules
- No cleanup actions, no mutations

### Cross-module improvements

- **Caches**
  - Owner attribution now derived from Inventory when possible
  - Reduced false “unknown owner” cases
  - More accurate app naming (bundle ID → app name)
- **App leftovers**
  - Installed-match detection now uses Inventory instead of loose heuristics
  - Improved bundle ID and group container correlation
  - Fewer false positives for still-installed apps
- **Launchd**
  - LaunchAgent/Daemon inspection uses Inventory-backed matching
  - Reduced reliance on static known-app lists
- **/usr/local/bin**
  - Binary ownership inference now aligns with Inventory and Homebrew data
  - Clearer distinction between Homebrew-managed and standalone binaries

Status: **stable, accuracy-focused release**

---

## v2.0.0 (released)

Focus: **contract-locked modules and startup visibility**

v2.0.0 formalizes mc-leaner’s module contract and introduces startup inspection as a first-class concern.
All modules now follow a consistent interface, output format, and safety model.

### Implemented modules

#### Startup (inspection-first)

- Inspect startup-related execution points:
  - LaunchAgents
  - LaunchDaemons
  - Login Items
- Classify startup timing (boot, login, on-demand)
- Distinguish user vs system scope
- Attribute owner when possible (Apple, vendor, user, unknown)
- Explain mode describing why each item exists and why it is flagged
- No automatic disabling or removal

### Structural guarantees

- Explicit module contract:
  - Inspection-first
  - No silent actions
  - Reversible cleanup only when explicitly requested
- Consistent logging, explain output, and summary reporting across all modules
- Inventory locked as the single source of truth for ownership and correlation

Status: **stable major release**

## v2.1.0 (released)

Focus: **flag transparency and disk visibility**

This release strengthens mc-leaner’s inspection guarantees by making all flagged items explicit in the run summary and by introducing disk usage inspection as a first-class module.

### Implemented modules

#### Disk inspection (inspection-first)

- Inspect large disk consumers across common user and system locations
- Flag paths exceeding a configurable size threshold (default: 200MB)
- Attribute ownership using the inventory index when possible
- Classify disk usage by category (e.g. Toolchains, Apps, Data)
- Inspection-only by default; no deletion or mutation

### Cross-module improvements

- Explicit flagged-item reporting
  - All flag-capable modules now export newline-delimited flagged identifiers
  - Run summary lists every flagged item per module
  - Output is stable, readable, and automation-friendly

- Timing attribution
  - Per-module durations included in the end-of-run summary

Status: **released**

## v2.2.0 (released)

Focus: **startup impact & performance attribution**

This release deepens startup inspection by answering why a system may feel slow at boot or login, without introducing any cleanup or disabling behavior.

### Startup inspection enhancements

- Impact classification per startup item:
  - low | medium | high
- Heuristics based on:
  - boot vs login timing
  - system vs user scope
  - known heavy agents (security, sync, virtualization)
  - unknown owner outside system locations
- Aggregated startup summary:
  - boot vs login flagged counts
  - conservative estimated startup risk indicator
- Best-effort startup timing attribution included in run summary
- Explicit guarantee: startup inspection never modifies system behavior

### Cross-module alignment

- Startup module fully aligned with the locked inspection-only module contract
- Timing output standardized for inclusion in end-of-run summaries

Status: **released**

## v2.3.0 (released)

Focus: **summary normalization and safer attribution**

This release standardizes end-of-run summary output and tightens attribution safety without changing the inspection-only posture.
Summary: summary normalization, move contract unification, safer attribution, service visibility records, and startup system opt-in.

### Cross-module improvements

- Run summary normalized to `module key=value` formatting
- Shared move contract (`move_attempt`) used consistently by move-capable modules
- Disk ownership attribution tightened to strict inventory lookups
- Shared helper utilities reduce duplication (temp files, redaction, attribution)
- Owner attribution output sanitized to prevent stray tab escape sequences in logs
- Inventory index paths consistently redacted in module logs (basename only in explain)
- Launchd summary clarified with `plists_checked` to avoid service/plist count confusion
- Startup scan defaulted to user scope; system launchd items require explicit opt-in
- Per-module timing stabilized so durations survive RETURN traps

Status: **released**

---

## v2.4.0 (in progress)

Focus: **output flexibility and restore safety**

- JSON summary output with `--json-file`
- Report export (`--export`)
- Backup management (`--list-backups`, `--restore-backup`) with checksum validation
- Config file support (`~/.mcleanerrc`) with CLI override precedence
- Progress indicator (`--progress`)

---

## v3.0 (long term)

Focus: **self-contained inspection application**

v3.0 introduces a self-contained app built on top of the existing CLI logic,
after module outputs and explain narratives have stabilized.

### Direction

- Thin UI wrapper over existing inspection modules
- Read-only by default
- No background daemons
- No automatic cleanup actions
- Report export and visualization focused

Any UI must remain transparent, auditable, and subordinate to the CLI.

---

## Explicit non-goals

mc-leaner will **not** become:

- A background daemon
- A system optimizer
- A RAM or performance booster
- A one-click “clean my Mac” tool
- A closed-source product

---

## Long-term direction

If mc-leaner grows, it will grow as:

- a modular inspection toolkit
- a learning tool for understanding macOS internals
- a CLI-first project with optional UI layers

Any future UI will be a thin wrapper over transparent logic.

---

## Feature proposals

Feature requests are welcome, but must answer:

1. What visibility problem does this solve?
2. What is the failure mode?
3. How is the action reversible?
4. Why should this exist in mc-leaner specifically?

If these questions cannot be answered clearly, the feature likely does not belong here.
