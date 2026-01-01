# mc-leaner

![macOS](https://img.shields.io/badge/macOS-supported-brightgreen)
![Bash](https://img.shields.io/badge/bash-3.2%2B-blue)
![License](https://img.shields.io/badge/license-MIT-lightgrey)
![Status](https://img.shields.io/badge/status-early--but--stable-orange)

**mc-leaner** is a safe-by-default macOS cleaner for people who want control, not magic.

It helps you **identify and remove leftover system clutter**—especially launchd orphans and legacy binaries—**without breaking your system**.

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

### Binary inspection
- Optionally inspects `/usr/local/bin` for legacy or unmanaged binaries
- Conservative and heuristic-based by design

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

---

## Restore

1. Open the backup folder created on your Desktop  
2. Move files back to their original locations  
3. Reboot

---

## Project structure (designed for expansion)

```text
mc-leaner/
├── docs/
│   ├── FAQ.md
│   ├── ROADMAP.md
│   └── SAFETY.md
├── mc-leaner.sh
├── modules/
│   ├── launchd.sh
│   ├── bins.sh
│   ├── intel.sh
│   ├── caches.sh        # planned
│   ├── brew.sh          # planned
│   ├── leftovers.sh    # planned
│   ├── logs.sh          # planned
│   └── permissions.sh  # planned
├── lib/
├── config/
├── docs/
├── assets/
├── CODING_STANDARDS
├── CONTRIBUTING
└── LICENSE
```

---

## Roadmap (high level)

Future modules focus on **visibility first, cleanup second**:

- User-level cache inspection
- Homebrew hygiene and diagnostics
- App uninstall leftovers
- Log growth analysis
- Privacy and permissions audit

No auto-clean. No silent behavior.

---

## Disclaimer

This software is provided “as is”, without warranty of any kind.  
You are responsible for reviewing and approving every action.
