# mc-leaner

![McLeaner Social Image](assets/logo/mcleaner-logo_Image.svg)

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

## What mc-leaner does (v1)

### Launchd hygiene

- Scans:
  - `/Library/LaunchAgents`
  - `/Library/LaunchDaemons`
  - `~/Library/LaunchAgents`
- Detects **suspected orphaned** launchd plists by:
  - skipping active `launchctl` jobs
  - skipping known installed apps
  - skipping Homebrew-managed services
  - skipping known security and endpoint software
- Prompts before every action
- Moves files to a **timestamped backup folder** on your Desktop
- Supports `--explain` flag to provide detailed reasoning per item

### /usr/local/bin inspection

- Optionally inspects `/usr/local/bin` for legacy or unmanaged binaries
- Conservative and heuristic-based by design
- Supports `--explain` flag to clarify detection logic

### Cache inspection (user-level)

- Inspects large user-level cache directories only:
  - `~/Library/Caches/*`
  - `~/Library/Containers/*/Data/Library/Caches`
- Reports:
  - cache size
  - last modified time
  - best-effort owning app or bundle identifier
- Groups caches by app for easier review
- `--explain` flag shows top subfolders by size within each cache
- Inspection-first by default (no moves)
- Optional cleanup:
  - requires `--apply`
  - user-confirmed per cache
  - moves caches to backup (never deletes)

#### Example output (inspect mode)

```text
[2026-01-02 14:14:33] Caches: scanned 88 directories; found 4 >= 200MB.

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

CACHE GROUP: WhatsApp (net.whatsapp.WhatsApp)
CACHE? 643MB | modified: 2025-11-13 17:44:31 | owner: WhatsApp
  path: ~/Library/Caches/net.whatsapp.WhatsApp
  Subfolders (top 3 by size):
    - 643MB | org.sparkle-project.Sparkle

CACHE GROUP: ms-playwright
CACHE? 476MB | modified: 2025-09-30 10:56:42 | owner: ms-playwright
  path: ~/Library/Caches/ms-playwright
  Subfolders (top 3 by size):
    - 297MB | chromium-1193
    - 176MB | chromium_headless_shell-1193
    - 2MB   | ffmpeg-1011

Caches: total large caches (by heuristics): 3356MB
```

### Architecture reporting

- Generates a report of **Intel-only executables** at:
  - `~/Desktop/intel_binaries.txt`
- Reporting only. No removal.

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

## Usage

Recommended first run (dry-run, no files moved):

```bash
bash mc-leaner.sh
```

Interactive clean (moves items to backup, never deletes):

```bash
bash mc-leaner.sh --mode clean --apply
```

Generate Intel-only executable report:

```bash
bash mc-leaner.sh --mode report
```

Inspect large user-level caches (dry-run):

```bash
bash mc-leaner.sh --mode caches-only
```

Inspect and optionally relocate large user-level caches:

```bash
bash mc-leaner.sh --mode caches-only --apply
```

Run a specific module:

```bash
# launchd only (dry-run)
bash mc-leaner.sh --mode launchd-only

# launchd only (apply)
bash mc-leaner.sh --mode launchd-only --apply

# /usr/local/bin only (dry-run)
bash mc-leaner.sh --mode bins-only

# /usr/local/bin only (apply)
bash mc-leaner.sh --mode bins-only --apply
```

Use the `--explain` flag to get detailed explanations of findings:

```bash
# launchd only with explanations
bash mc-leaner.sh --mode launchd-only --explain

# /usr/local/bin inspection with explanations
bash mc-leaner.sh --mode bins-only --explain

# caches inspection showing top subfolders
bash mc-leaner.sh --mode caches-only --explain
```

All commands default to dry-run unless `--apply` is explicitly provided.

---

## Restore

1. Open the backup folder created on your Desktop  
2. Move files back to their original locations  
3. Reboot

---

## Project structure (designed for expansion)

```text
mc-leaner/
├── mc-leaner.sh
├── modules/
│   ├── launchd.sh
│   ├── bins_usr_local.sh
│   ├── intel.sh
│   ├── caches.sh        # user-level cache inspection (implemented)
│   ├── brew.sh          # planned
│   ├── leftovers.sh     # planned
│   ├── logs.sh          # planned
│   └── permissions.sh   # planned
├── lib/
│   ├── cli.sh
│   ├── ui.sh
│   ├── fs.sh
│   ├── safety.sh
│   └── utils.sh
├── config/
│   ├── protected-labels.conf   # security & never-touch rules
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

Future modules focus on **visibility first, cleanup second**:

- Homebrew hygiene and diagnostics
- App uninstall leftovers
- Log growth analysis
- Privacy and permissions audit

No auto-clean. No silent behavior.

---

## Disclaimer

This software is provided “as is”, without warranty of any kind.  
You are responsible for reviewing and approving every action.
