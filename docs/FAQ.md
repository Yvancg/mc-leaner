# FAQ

## Is mc-leaner safe?

Yes, by design.

mc-leaner is **safe by default**:

- It runs in dry-run mode unless you explicitly use `--apply`
- It never deletes files
- All changes are reversible via a backup folder
- Security and endpoint protection software is always skipped
- All modules in v2.2.0 follow an inspection-first contract with explicit user confirmation for any changes

That said, mc-leaner is a **power tool**. You are expected to read prompts and understand what you approve.

---

## How is this different from CleanMyMac or similar tools?

mc-leaner does the opposite of most commercial Mac cleaners.

Most cleaners:

- hide what they remove
- delete files permanently
- bundle many actions behind one button
- prioritize speed over safety

mc-leaner:

- shows you exactly what it finds
- asks before every action
- moves files instead of deleting them
- favors inspection over cleanup

If you want a one-click solution, mc-leaner is not for you.

---

## Can mc-leaner break my system?

It is designed not to.

However, macOS maintenance always carries risk if you remove things blindly. This is why:

- nothing is removed automatically
- system-critical and security-related services are skipped
- you can always restore from backup
- protected system, Apple-owned, and security-related paths are automatically skipped

If something behaves unexpectedly, restore the files and reboot.

---

## Why does mc-leaner flag something I still use?

Detection is heuristic.

Some background services:

- belong to apps you still use occasionally
- were installed by older versions of apps
- are managed externally (for example by Homebrew)

mc-leaner flags items for **review**, not removal. If you still use an app, keep its services.

---

## Why does the run summary list every flagged item?

As of v2.2.0, mc-leaner always lists the identifiers of all flagged items in the end-of-run summary.

This is intentional.

Counts alone are ambiguous. Explicit lists allow you to:

- see exactly *what* was flagged
- correlate findings across modules
- review results later without scrolling through raw logs
- use mc-leaner output in scripts or audits

Nothing is hidden behind summary numbers anymore.

---

## What does the Caches module actually do?

The Caches module is **inspection-first**.

It scans user-level cache locations and highlights **large cache directories** based on conservative size thresholds. For each cache group, it reports:

- total size
- last modification time
- owning app (derived from the Inventory when possible)
- largest subfolders (with `--explain`)

By default, nothing is moved or removed.

If you use `--apply`, mc-leaner will:

- prompt you per cache group
- move selected caches to a backup folder
- never delete anything

This allows you to safely reclaim space without guessing.

The Caches module accepts `--explain` and inventory context like other inspection modules.

---

## What is the Inventory module?

The Inventory module (introduced in v1.6.0, contract-locked in v2.1.0) is a **foundational inspection module**.

It builds a live inventory of installed software, including:

- system and user applications
- application bundle identifiers
- application paths
- Homebrew formulae and casks

In v2.1.0, the Inventory is the single source of truth for ownership and matching across all inspection modules.

This inventory is used internally by other modules to improve accuracy and reduce false positives.

For example, it allows mc-leaner to:

- correctly associate caches, logs, and leftovers with installed apps
- distinguish real leftovers from data belonging to active software
- avoid heuristic name matching when reliable identifiers are available

The Inventory module does not remove, modify, or move anything. It exists purely to provide a reliable source of truth for other inspections.

---

## What does the Logs module do, and is it safe?

The Logs module is **inspection-first**.

It scans key system and user log locations:

- `~/Library/Logs`
- `/Library/Logs`
- `/var/log`

By default, it reports:

- size
- last modified time
- related log rotations
- top subfolders for large directories

With `--apply`, logs can be moved to a backup folder **only after explicit confirmation**.

No logs are ever deleted automatically.

---

## What does the Disk module do?

The Disk module (introduced in v2.1.0) is **inspection-first**.

It scans for large disk consumers across common user and system locations and flags paths that exceed conservative size thresholds.

For each flagged path, it reports:

- total size
- path
- inferred owner (via the Inventory when possible)
- confidence level
- category (for example Toolchains, Apps, Data)

Nothing is removed by default.

With `--apply`, the Disk module still does **not** delete files. It only reports and summarizes disk usage so you can decide what to investigate further.

---

## What does the Permissions module do?

The Permissions module (introduced in v1.5.0) is **inspection-only**.

It checks whether mc-leaner is running in an environment that allows reliable inspection, and reports:

- whether the session is interactive
- which host application launched mc-leaner (Terminal, VS Code, etc.)
- whether GUI prompts are available
- whether known TCC-protected locations are accessible or blocked

This module **does not change any permissions**, request new access, or modify system settings.

Its purpose is diagnostic: to explain *why* certain paths may be skipped or partially scanned on modern macOS versions.

Nothing is moved or modified, even with `--apply`.

---

## What does the App Leftovers module do?

The App Leftovers module (introduced in v1.4.0) is **inspection-first**.

It scans common user-level support locations such as:

- `~/Library/Application Support`
- `~/Library/Containers`
- `~/Library/Group Containers`
- `~/Library/Preferences`

It identifies **candidate leftover folders** that:

- exceed conservative size thresholds
- are not owned by protected Apple or security components
- do not match currently installed applications according to the Inventory

For each candidate, mc-leaner reports:

- size
- last modification time
- inferred owner or bundle identifier
- why the item was flagged or skipped

By default, nothing is moved.

With `--apply`, mc-leaner:

- prompts you *per item*
- moves approved folders to a backup location
- never deletes anything

All decisions are explicit and reversible.

---

## What does the Startup module do?

The Startup module is introduced in v2.2.0.

It inspects startup-related execution paths including LaunchAgents, LaunchDaemons, and Login Items.

The module is inspection-first and does not disable, unload, or remove anything automatically.
It never modifies startup behavior.

It reports:

- trigger type (boot or login)
- source type (LaunchAgent, LaunchDaemon, Login Item)
- label
- executable path
- inferred owner (via Inventory)
- why an item is flagged

Items with unknown or ambiguous ownership are flagged for review.

Apple system and protected services are reported but never modified.

As of v2.1.0, all flagged startup items are also listed explicitly in the run summary so you can review them without searching through inline output.

---

## What is the Homebrew hygiene module?

The Homebrew module (introduced in v1.3.0) is **inspection-only** in its initial form.

It focuses on:

- identifying unused formulae and casks
- highlighting large Homebrew cache and download artifacts
- detecting stale or orphaned Homebrew-managed files

There is no automatic cleanup or uninstall actions.

All output is informational unless future versions explicitly add safe, confirmed actions.

The Homebrew module never removes, uninstalls, or modifies Homebrew state.

As of v1.6.0, Homebrew data is also used by the Inventory module to improve ownership detection across other modules.

---

## Does mc-leaner work on Apple Silicon?

Yes.

mc-leaner is fully compatible with Apple Silicon Macs. One of its features is reporting **Intel-only executables** so you can decide whether legacy software is still worth keeping.

Intel-only binaries are **reported only** and are never modified or removed by mc-leaner.

---

## Why doesn’t mc-leaner delete files automatically?

Because deletion is irreversible.

mc-leaner is built around:

- reversibility
- transparency
- user intent

Automatic deletion would violate all three.

---

## Is mc-leaner really open source, and will it stay that way?

Yes.

mc-leaner follows an **open-core model**:

- The core inspection engine, safety logic, and decision-making code are fully open source.
- This repository remains the reference implementation for how mc-leaner works.
- Anyone can audit, fork, or build on top of the core logic.

In the future, there will be **commercial layers** built on top of this core, such as:

- a graphical interface
- packaged distributions
- signed binaries
- convenience or support features

These layers will not be required to understand, verify, or trust mc-leaner’s behavior.

Transparency is not a feature. It is the foundation of the project.

---

## Will mc-leaner add a GUI?

Possibly, but not at the expense of transparency.

Any future UI would be a thin wrapper over the same visible logic. The CLI will remain the reference implementation.

---

## Why does mc-leaner show so much detail?

Because context matters.

Large caches and logs are not inherently bad. What matters is:

- how large they are
- whether they are still active
- whether you can safely remove them

mc-leaner provides enough information so *you* can decide, instead of guessing.

---

## Can I contribute a new cleanup idea?

Yes, if it follows the project philosophy.

Before proposing a feature, ask:

1. What visibility problem does this solve?
2. What is the worst failure mode?
3. How can the user undo it?
4. Why should this live in mc-leaner?

See CONTRIBUTING.md for details.

---

## Does mc-leaner run things I did not ask for?

mc-leaner only runs modules explicitly selected by the chosen mode.

The default scan mode runs all inspection modules, including new ones introduced in v2.1.0 such as Startup, but performs no destructive actions.

Any file movement or cleanup requires explicit use of `--apply`.

If mc-leaner is running in a non-interactive context and cannot prompt safely, it will **skip the action** and report the reason. No file is ever moved without an explicit confirmation.
