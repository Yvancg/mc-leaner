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

## v2.x (medium term)

Focus: **system understanding, not removal**

### Planned modules

#### Permissions audit

- Report apps with:
  - Full Disk Access
  - Accessibility
  - Screen Recording
- No changes, visibility only

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
