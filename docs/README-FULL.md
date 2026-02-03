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

As of v2.4.0, all modules follow a strict inspection-first contract, share a unified inventory core, and produce explicit, reviewable run summaries.

### Release highlights

#### v2.4.0 (unreleased)

**Output, restore safety, and configurability**

- Configurable thresholds for caches/logs/leftovers/disk (CLI + config file)
- JSON summary output with optional `--json-file`
- Report export with `--export`
- Backup management (`--list-backups`, `--restore-backup`) with checksum validation
- Progress indicator (`--progress`)
- Startup items include `impact_s` (seconds estimate)

#### v2.3.0

**Summary normalization & safer attribution**

- Run summary now uses consistent `module key=value` formatting
- Move-capable modules use the shared `move_attempt` contract for consistent failure reporting
- Disk ownership attribution is inventory-first with conservative heuristics
- Shared helper utilities reduce per-module duplication (temp files, redaction, attribution)
- Background service visibility records (`SERVICE?`) with conservative network-facing classification
- Startup scan defaults to user scope; system launchd requires `--startup-system`
- Inventory index paths are consistently redacted in module logs
- Per-module timing is stabilized under strict shell

#### v2.2.0

**Startup impact & performance attribution**

- Startup inspection now estimates impact per item (low, medium, high)
- Run summary includes boot vs login flagged counts and a conservative startup risk signal
- End-of-run timing includes per-module durations (startup, launchd, caches, logs, disk, leftovers)
- No behavior changes: inspection-only, no disabling, unloading, or removal

#### v2.1.0

**Disk inspection & flag transparency**

- Inspects large disk consumers across common user and system locations
- Flags paths exceeding a configurable size threshold (default: 200MB)
- Attributes ownership using the inventory index where possible
- Reports:
  - path
  - total size
  - inferred owner
  - confidence level
  - category (e.g. Toolchains, Apps, Data)
- Inspection-first by default; no files are removed
- Designed to answer: *what is using my disk space, and why?*

**Flag transparency & structured reporting**

- Flag-capable modules now export newline-delimited `*_FLAGGED_IDS_LIST` variables
  - startup, launchd, caches, logs, leftovers, disk
- Enables consistent, structured reporting of *what* was flagged, not just counts
- Run summary now includes:
  - flagged item counts per module
  - flagged sizes where applicable
- Clean, multi-line run summary output suitable for terminals and logs

#### v2.0.0

**Inventory-backed inspection & startup visibility**

- Locks the v2 module contract and run summary semantics
- All inspection modules rely on a shared, explicit inventory layer for ownership and installed-state decisions
- Output format is stable and explainable for scripting and long-term support

**Startup inspection**

- Inspects LaunchDaemons, LaunchAgents, and Login Items
- Classifies startup scope (boot vs login), source, owner, and execution path
- Flags unknown or non-inventory-backed startup entries
- Inspection-first design with no destructive actions

**Module contract (v2) & orchestration**

- Standardized entrypoint naming: `run_<module>_module`
- Unified logging, `--explain` output, and run summary semantics
- Deterministic module ordering with explicit availability checks and graceful degradation

**Safety & resilience**

- Hardened strict-shell behavior across modules (no silent failures under `set -u`)
- Consistent non-destructive guarantees across inspection modules
- Stable full-system scan and clean passes, including `--explain` coverage

#### v1.6.0

**Inventory-driven accuracy across all modules**

- Adds the inventory core module for centralized discovery of:
  - installed applications
  - bundle identifiers
  - executable roots
- Shared inventory used consistently by caches, leftovers, bins, launchd, and intel modules
- Lazy, on-demand population to reduce startup cost and unnecessary scans
- Explicit readiness checks to prevent partial or inconsistent state usage

**Fixes & reliability under strict shell**

- Fixed unbound variable and array edge cases under strict shell settings
- Corrected cache ownership reporting for Chromium-based applications
- Eliminated inventory-dependent race conditions during `--explain` scans

**Module improvements**

- Caches: more accurate owner attribution and fewer false positives
- Leftovers: stronger installed-app matching for group containers and bundle-id prefixes
- Intel-only scan: stable root discovery via inventory-provided application paths and deduplicated roots
- Orchestration: clearer module boundaries and more predictable execution order

#### v1.5.0

**Permissions inspection**

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

#### v1.4.0

**App leftovers inspection**

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

#### v1.3.0

**Homebrew hygiene**

- Inspection-first diagnostics for Homebrew-managed systems
- Intended checks:
  - orphaned formulae and casks
  - unused dependencies
  - outdated or disabled services
  - stale cache and download artifacts
- Read-only by default
- No `brew cleanup`, `brew autoremove`, or destructive commands
- Designed to explain *why* Homebrew reports certain states before suggesting actions

This module focuses on **understanding Homebrew state**, not blindly cleaning it.

#### v1.2.0

**Log inspection**

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

#### v1.1.0

**Cache inspection**

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

##### Example output (inspect mode)

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

#### v1.0.0

**Launchd hygiene**

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

**/usr/local/bin inspection**

(corresponds to `--mode bins-only`)

- Optionally inspects `/usr/local/bin` for legacy or unmanaged binaries
- Conservative and heuristic-based by design
- Supports `--explain` flag to clarify detection logic
- Uses inventory-backed Homebrew and installed-software correlation

**Architecture reporting**

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

### Flagged item transparency (v2.1.0)

As of v2.1.0, mc-leaner now provides:

- Explicit lists of all flagged items in the end-of-run summary
- One item per line, grouped by module
- Stable, grep-friendly output suitable for logs, CI, and audits

This ensures you can always answer:

- *What exactly was flagged?*
- *By which module?*
- *In which execution mode?*

Counts are no longer detached from the underlying items.

### Timing attribution (v2.2.0)

- Per-module wall-clock durations are included in the run summary
- Helps attribute slow runs to specific inspection phases

1. **Dry-run by default**  
   Nothing is moved unless you explicitly use `--apply`.

2. **No destructive actions**  
   Files are moved, never deleted.

3. **Hard protection rules**  
   Known security and endpoint tools are always skipped.

4. **User-controlled scope**  
   You decide which modules run.

5. **Always reversible**  
   Restore with `--restore-backup` (or move files back manually) and reboot.

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
  **Note:** `--apply` must be explicitly provided on the CLI (config files cannot enable it).

- `--explain`  
  Shows detailed reasoning for why items are flagged or skipped. Strongly recommended before applying any changes.

- `--mode <name>`  
  Runs a single module instead of the default full scan.  
  Examples: `launchd-only`, `caches-only`, `logs-only`, `leftovers-only`, `brew-only`.

- `--help`  
  Prints a short help message with available modes and exits.

- `--mode startup-only`  
  Runs startup inspection module only (inspection-first, no cleanup).

- `--threshold <list>`  
  Comma list of thresholds (MB). Example: `caches=300,logs=100,leftovers=75,disk=500`.

- `--threshold-caches <mb>` / `--threshold-logs <mb>` / `--threshold-leftovers <mb>` / `--threshold-disk <mb>`  
  Override per-module thresholds (MB).

- `--json`  
  Emit a JSON summary to stdout (captures machine records).

- `--json-file <path>`  
  Write the JSON summary to a separate file.

- `--export <path>`  
  Write a full report to a file (human logs + machine records).

- `--list-backups`  
  List backup folders created on this machine.

- `--restore-backup <path>`  
  Restore items from a backup folder (uses checksum-validated manifest; prompts per item).

- `--progress`  
  Emit a simple progress indicator per module.

**Important:**  
If mc-leaner cannot prompt for confirmation (non-interactive run), cleanup actions are skipped automatically for safety.

---

## Config file (~/.mcleanerrc)

mc-leaner reads a simple key=value config file at `~/.mcleanerrc` before CLI parsing. CLI flags always win.

Example:

```ini
mode=scan
explain=true
threshold=caches=300,logs=100
json=true
json_file=~/Desktop/mc-leaner.json
export=~/Desktop/mc-leaner_report.txt
progress=true
```

**Safety note:** `apply=true` in the config is ignored unless you also pass `--apply` on the CLI.

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
  The run summary will list every flagged item per module for easy review.

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
  bash mc-leaner.sh --mode report
  ```

  Optional helpers:

  ```bash
  bash mc-leaner.sh --threshold caches=300,logs=100
  bash mc-leaner.sh --json
  bash mc-leaner.sh --json-file ~/Desktop/mc-leaner.json
  bash mc-leaner.sh --export ~/Desktop/mc-leaner_report.txt
  bash mc-leaner.sh --progress
  ```

  **Note:** `report` is reporting-only. It never performs cleanup actions and does not support `--apply`.

5. Apply moves only when you are ready

  ```bash
  bash mc-leaner.sh --mode leftovers-only --apply
  ```

  You will be prompted per item. Files are **moved to a backup folder**, never deleted.

6. Restore if needed

- List backups: `bash mc-leaner.sh --list-backups`
- Restore: `bash mc-leaner.sh --restore-backup <backup_dir>`
- Reboot if the item relates to launchd or system services

Restore uses a checksum-validated manifest; if the checksum is missing, restore manually by moving files back.

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
│   ├── inventory.sh      # inventory core (apps, bundle IDs, Homebrew, index)
│   ├── launchd.sh        # launchd plist inspection (agents & daemons)
│   ├── bins_usr_local.sh # /usr/local/bin inspection for unmanaged binaries
│   ├── intel.sh          # Intel-only executable reporting (informational)
│   ├── caches.sh         # user-level cache inspection (implemented)
│   ├── brew.sh           # Homebrew hygiene (inspection-only, implemented)
│   ├── leftovers.sh      # app leftovers inspection (implemented)
│   ├── logs.sh           # log inspection (implemented)
│   ├── startup.sh        # startup and login item inspection (inspection-only)
│   ├── disk.sh           # disk usage attribution (inspection-only)
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
  - JSON schema stabilization and report file ergonomics

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
