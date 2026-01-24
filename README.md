# mc-leaner

![McLeaner Logo](assets/logo/mcleaner-logo_Image.svg)

![macOS](https://img.shields.io/badge/macOS-supported-brightgreen)
![Bash](https://img.shields.io/badge/bash-3.2%2B-blue)
![License](https://img.shields.io/badge/license-MIT-lightgrey)
![Status](https://img.shields.io/badge/status-early--but--stable-orange)
[![Security Policy](https://img.shields.io/badge/security-policy-blue)](SECURITY.md)

**mc-leaner** is a safe-by-default macOS cleaner for people who want control, not magic.

It helps you **identify and safely relocate leftover system clutter**—especially launchd orphans and legacy binaries—**without breaking your system**.

No silent actions.  
No “optimization.”  
No deletions.

---

## Open source status

mc-leaner is an **open-source project**.

- The full inspection and safety logic is public and auditable.
- All decisions made by the tool can be traced and explained.
- Contributions, forks, and independent reviews are encouraged.

The long-term direction of the project follows an **open-core model**:

- This repository will remain open and focused on the core inspection engine.
- Future commercial offerings, will be layered on top.
- No proprietary features will be required to understand or trust what mc-leaner does.

If you value transparency and control, this repository is the source of truth.

---

## Philosophy

mc-leaner is built on a simple idea:

> macOS maintenance should be **inspectable, reversible, and boring**.

Most “Mac cleaner” tools are dangerous because they:

- delete things you cannot easily restore
- hide what they are doing
- optimize for speed, not safety

mc-leaner takes the opposite approach:

- everything is opt-in
- everything is explained
- everything can be undone

If you want a button that says *“Clean My Mac”*, this tool is not for you.

If you want to understand what is running on your system—and clean it safely—this is.

---

## What mc-leaner does (current)

As of v2.0.0, all modules follow a strict inspection-first contract and share a unified inventory core.

### Inventory core (v2.0.0 – contract)

- Introduces a centralized inventory index of installed software (apps, bundle IDs, Homebrew formulae and casks).
- Used across modules to replace ad-hoc heuristics with consistent lookups.
- Improves accuracy for ownership detection, installed-match decisions, and skip logic.
- Runs once per execution and is reused by all inspection modules.
- Fully explainable with --explain (sources, match type, normalization path).
- Acts as the single source of truth for ownership, installed-state, and skip decisions across all modules.

### Startup inspection (v2.0.0)

- Inspects system and user startup mechanisms without modifying state
- Sources include:
  - launchd agents and daemons
  - login items
- Classifies startup entries by:
  - boot vs login
  - source type (LaunchAgent, LaunchDaemon, LoginItem)
  - owner (Apple system, installed app, unknown)
- Uses inventory to resolve known apps and bundle identifiers
- Flags unknown or unmanaged startup items for review
- Inspection-only; no cleanup actions are performed
- Fully explainable with --explain

### Launchd hygiene

- Scans:
  - `/Library/LaunchAgents`
  - `/Library/LaunchDaemons`
  - `~/Library/LaunchAgents`
- Detects **suspected orphaned or unmanaged** launchd plists by:
  - skipping active `launchctl` jobs
  - skipping known installed apps
  - skipping Homebrew-managed services
  - skipping known security and endpoint software
- Uses inventory-based installed app and bundle-id resolution
- Prompts before every action
- Moves files to a **timestamped backup folder** on your Desktop
- Supports `--explain` flag to provide detailed reasoning per item

### /usr/local/bin inspection

(corresponds to `--mode bins-only`)

- Optionally inspects `/usr/local/bin` for legacy or unmanaged binaries
- Conservative and heuristic-based by design
- Supports `--explain` flag to clarify detection logic
- Uses inventory-backed Homebrew and installed-software correlation

### Cache inspection (v1.1.0)

- Inspects large user-level cache directories only:
  - `~/Library/Caches/*`
  - `~/Library/Containers/*/Data/Library/Caches`
- Reports:
  - cache size
  - last modified time
  - best-effort owning app or bundle identifier
- Groups caches by app for easier review
- Uses inventory-backed owner labeling and reduced false "unknown owner"
- `--explain` flag shows top subfolders by size within each cache
- Inspection-first by default (no moves)
- Optional cleanup:
  - requires `--apply`
  - user-confirmed per cache
  - moves caches to backup (never deletes)

#### Example output (inspect mode)

```text
[2026-01-02 14:14:33] Caches: scanned 88 directories; found 2 >= 200MB.

CACHE GROUP: Google
CACHE? 1799MB | modified: 2025-02-03 13:13:57 | owner: Google
  path: ~/Library/Caches/Google
  Subfolders (top 3 by size):
    - 1799MB | Chrome

CACHE GROUP: Homebrew
CACHE? 438MB | modified: 2026-01-02 12:27:04 | owner: Homebrew
  path: ~/Library/Caches/Homebrew
  Subfolders (top 3 by size):
    - 366MB | downloads
    - 46MB  | api
    - 13MB  | bootsnap

Caches: total large caches (by heuristics): 3356MB
```

### Log inspection (v1.2.0)

- Inspects log files and directories exceeding a size threshold (default: 50MB)
- Scans:
  - `~/Library/Logs`
  - `/Library/Logs`
  - `/var/log`
- Reports:
  - size
  - last modified time
  - best-effort owning app or subsystem
- Groups related logs where possible
- `--explain` flag provides:
  - rotation siblings (e.g. `.1`, `.2`, `.gz`)
  - top subfolders by size for large log directories
- Inspection-first by default (no moves)
- Optional cleanup:
  - requires `--apply`
  - user-confirmed per item
  - moves logs to backup (never deletes)
  - system paths may require explicit confirmation and are skipped in non-interactive contexts

### Homebrew hygiene (v1.3.0)

- Inspection-first diagnostics for Homebrew-managed systems
- Intended checks:
  - orphaned formulae and casks
  - unused dependencies
  - outdated or disabled services
  - stale cache and download artifacts
- Read-only by default
- No `brew cleanup`, `brew autoremove`, or destructive commands
- Designed to explain *why* Homebrew reports certain states before suggesting actions

This module will focus on **understanding Homebrew state**, not blindly cleaning it.

### App leftovers inspection (v1.4.0)

- Inspects user-level support locations for leftover data from uninstalled apps
- Scans locations including:
  - `~/Library/Containers`
  - `~/Library/Group Containers`
  - `~/Library/Application Support`
  - `~/Library/Preferences`
  - `~/Library/Saved Application State`
- Uses bundle-id matching against installed apps to avoid false positives
- Skips Apple/system-owned containers and protected software
- Applies a size threshold (default: 50MB) to reduce noise
- Uses inventory-first matching before heuristic normalization
- Inspection-first by default (no moves)
- Optional cleanup:
  - requires `--apply`
  - user-confirmed per item
  - relocates folders to backup (never deletes)
- Designed for reviewing old app remnants, not active application data

### Permissions inspection (v1.5.0)

- Inspects execution environment and permission boundaries
- Detects:
  - interactive vs non-interactive runs
  - host application context (Terminal, VS Code, etc.)
  - GUI prompt availability
  - accessible vs restricted system locations
- Explains why certain actions are skipped for safety
- Integrated into full scan and available as `permissions-only` mode
- Inspection-only; never performs cleanup actions
- Supports `--explain`

### Architecture reporting

- Generates a report of **Intel-only executables (no arm64 slice)** at:
  - `~/Desktop/intel_binaries.txt`
- Intel-only does not mean unsafe; this is informational for Apple Silicon users.
- Reporting only. No removal.
- Scans common application and support paths for executable files only

---

## What it explicitly does NOT do

- No file deletion
- No app uninstallation
- No modification of app bundles
- No system “optimization”
- No background or automated runs

Every action requires user confirmation.

---

## Safety model

1. **Dry-run by default**  
   Nothing is moved unless you explicitly use `--apply`.

2. **No destructive actions**  
   Files are moved, never deleted.

3. **Hard protection rules**  
   Known security and endpoint tools are always skipped.

4. **User-controlled scope**  
   You decide which modules run.

5. **Always reversible**  
   Restore by moving files back and rebooting.

---

## Requirements

- macOS
- Bash (macOS default supported)
- `launchctl` (built-in)
- `osascript` (optional, for GUI prompts)
- Homebrew (optional, improves detection accuracy)

---

## Global flags

mc-leaner uses a small set of global flags that apply consistently across all modules.

- `--apply`  
  Enables file relocation. Without this flag, mc-leaner runs in **dry-run mode** and performs no changes.

- `--explain`  
  Shows detailed reasoning for why items are flagged or skipped. Strongly recommended before applying any changes.

- `--mode <name>`  
  Runs a single module instead of the default full scan.  
  Examples: `launchd-only`, `caches-only`, `logs-only`, `leftovers-only`, `brew-only`.

- `--help`  
  Prints a short help message with available modes and exits.

- `--mode startup-only`  
  Runs startup inspection module only (inspection-first, no cleanup).

**Important:**  
If mc-leaner cannot prompt for confirmation (non-interactive run), cleanup actions are skipped automatically for safety.

---

## Usage

Follow this flow to stay safe and avoid surprises.

1. Clone the repository

  ```bash
  git clone https://github.com/Yvancg/mc-leaner.git
  cd mc-leaner
  ```

2. In your Terminal, run a safe scan first (default: dry-run)

  ```bash
  bash mc-leaner.sh
  ```

  Nothing is moved. This shows what *would* be flagged.

3. Inspect decisions with explanations (optional but recommended)

  ```bash
  bash mc-leaner.sh --explain
  ```

  Use this to understand why items are flagged or skipped.

4. Run one module at a time (recommended)

  Examples:

  ```bash
  bash mc-leaner.sh --mode launchd-only --explain
  bash mc-leaner.sh --mode bins-only --explain
  bash mc-leaner.sh --mode caches-only --explain
  bash mc-leaner.sh --mode logs-only --explain
  bash mc-leaner.sh --mode leftovers-only --explain
  bash mc-leaner.sh --mode brew-only --explain
  bash mc-leaner.sh --mode permissions-only --explain
  bash mc-leaner.sh --mode intel-only
  ```

  **Note:** `intel-only` is a reporting-only mode. It never performs cleanup actions and does not support `--apply`.

5. Apply moves only when you are ready

  ```bash
  bash mc-leaner.sh --mode leftovers-only --apply
  ```

  You will be prompted per item. Files are **moved to a backup folder**, never deleted.

6. Restore if needed

- Open the backup folder created on your Desktop
- Move items back to their original location
- Reboot if the item relates to launchd or system services

**Notes:**

- All modules are inspection-first by default
- If a prompt cannot be shown (non-interactive run), the move is skipped for safety
- See `docs/FAQ.md` for common questions and edge cases

---

## Project structure (designed for expansion)

```text
mc-leaner/
├── mc-leaner.sh
├── modules/
│   ├── launchd.sh        # launchd plist inspection (agents & daemons)
│   ├── bins_usr_local.sh # /usr/local/bin inspection for unmanaged binaries
│   ├── intel.sh          # Intel-only executable reporting (informational)
│   ├── caches.sh         # user-level cache inspection (implemented)
│   ├── brew.sh           # Homebrew hygiene (inspection-only, implemented)
│   ├── leftovers.sh      # app leftovers inspection (implemented)
│   ├── logs.sh           # log inspection (implemented)
│   ├── startup.sh        # startup and login item inspection (inspection-only)
│   └── permissions.sh    # execution context & permission inspection
├── lib/
│   ├── cli.sh
│   ├── ui.sh
│   ├── fs.sh
│   ├── safety.sh
│   └── utils.sh
├── config/
│   ├── protected-labels.conf   # security & never-touch rules (future)
│   └── modes.conf              # mode → module mapping (future)
├── docs/
│   ├── FAQ.md
│   ├── SAFETY.md
│   └── ROADMAP.md
├── assets/
│   └── social-preview.png
├── CONTRIBUTING.md
├── CODING_STANDARDS.md
├── README.md
└── LICENSE
```

---

## Roadmap (high level)

With v2.0.0, mc-leaner stabilizes its module contracts, inventory model, and output format. Future releases will focus on depth rather than breadth.

Planned directions:

- Refinement of existing modules
  - Reduce false positives further (especially leftovers and logs)
  - Improve ownership detection and reporting
  - Better handling of protected and system-managed paths

- UX and safety improvements
  - Clearer non-interactive behavior reporting
  - Improved summaries and decision transparency
  - Optional machine-readable report output (JSON)

- Documentation and governance
  - Expanded FAQ with real-world scenarios
  - Clearer contribution and review guidelines
  - Stability guarantees per module

Explicitly **out of scope**:

- Automatic cleanup
- Background agents or scheduled runs
- Deletion-based workflows
- “One-click” cleaning modes

See `docs/ROADMAP.md` for detailed and evolving planning.

---

## Disclaimer

This software is provided “as is”, without warranty of any kind.  
You are responsible for reviewing and approving every action.
