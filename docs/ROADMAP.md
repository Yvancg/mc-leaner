# mc-leaner Roadmap

This roadmap reflects the guiding philosophy of mc-leaner:

> **Visibility first. Cleanup second. Never silent.**

Dates are intentionally omitted. Features ship when they meet the safety bar.

---

## v1.x (current)

Focus: **launchd hygiene and visibility**

- LaunchAgents / LaunchDaemons orphan detection
- Hard skip rules for security and endpoint software
- Intel-only executable reporting
- Conservative `/usr/local/bin` inspection
- Dry-run by default, reversible actions

Status: **stable foundation**

---

## v2.x (short term)

Focus: **inspection before cleanup**

### Planned modules

#### Caches (inspection-first)

- List large user-level cache directories
- Show size, last modified, owning app
- Optional cleanup, user-level only

#### Homebrew hygiene

- Surface `brew doctor` issues
- Detect unlinked or outdated kegs
- Identify orphaned Homebrew services
- Suggest commands, do not execute automatically

#### App leftovers

- Detect files left behind after app uninstall:
  - Application Support
  - Preferences
  - Containers
- Correlate with missing app bundles

---

## v3.x (medium term)

Focus: **system understanding, not removal**

### Planned modules

#### Logs

- Identify large or rapidly growing logs
- Highlight misbehaving applications
- Reporting only by default

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
