# mc-leaner

![McLeaner Logo](assets/logo/mcleaner-logo_Image.svg)

![macOS](https://img.shields.io/badge/macOS-supported-brightgreen)
![Bash](https://img.shields.io/badge/bash-3.2%2B-blue)
![License](https://img.shields.io/badge/license-MIT-lightgrey)
![Status](https://img.shields.io/badge/status-early--but--stable-orange)
[![Security Policy](https://img.shields.io/badge/security-policy-blue)](SECURITY.md)

**mc-leaner** is a safe-by-default macOS inspection and cleanup tool for people who want **control, not magic**.

It helps you **identify what is running, consuming space, or lingering on your system**, and clean it **only when you explicitly choose to**.

No silent actions.  
No “optimization.”  
No deletions.

---

## Philosophy

> macOS maintenance should be **inspectable, reversible, and boring**.

Most “Mac cleaner” tools are dangerous because they hide what they do and act too quickly.

mc-leaner takes the opposite approach:

- inspection-first, always  
- explicit user confirmation for every change  
- everything explainable  
- everything reversible  

If you want a “Clean My Mac” button, this tool is not for you.

If you want to understand what is happening on your system and clean it safely, it is.

---

## What mc-leaner does (current)

mc-leaner inspects macOS systems for:

- Startup and login items (launchd agents, daemons, login items)
Startup inspection does not disable anything, system launchd items are opt-in, and items include impact seconds.
- Orphaned or unmanaged launchd plists
- Large caches and logs (configurable thresholds)
- Leftover data from uninstalled applications
- Large disk consumers with ownership attribution
- Intel-only executables on Apple Silicon (reporting only)
- Execution context and permission boundaries
- Background service visibility records (`SERVICE?`) for correlation
- JSON summary output and report export
- Backup management (list and restore with manifest checksum)
- Versioned JSON schema and `--version`

All modules are **inspection-only by default**.  
Cleanup actions require `--apply` and explicit confirmation.

---

## Safety model

- **Dry-run by default**  
  Nothing is moved unless you use `--apply`.

- **No destructive actions**  
  Files are moved to a timestamped backup folder, never deleted.

- **Hard protection rules**  
  Known security and endpoint software is always skipped.

- **Explicit transparency**  
  Every flagged item is listed in the run summary, one per line.

- **Always reversible**  
  Restore with `--restore-backup` (or move files back manually) and reboot if needed.

---

## Quick start (safe path)

Clone and run a safe inspection:

```bash
git clone https://github.com/Yvancg/mc-leaner.git
cd mc-leaner
bash mc-leaner.sh
```

Nothing is changed.  
The run summary shows exactly what would be flagged.

To understand *why* something is flagged:

```bash
bash mc-leaner.sh --explain
```

To run a single module:

```bash
bash mc-leaner.sh --mode startup-only --explain
bash mc-leaner.sh --mode disk-only
```

Optional: set defaults in `~/.mcleanerrc` (key=value). CLI flags always win.

To export a report or JSON summary:

```bash
bash mc-leaner.sh --export ~/Desktop/mc-leaner_report.txt
bash mc-leaner.sh --json-file ~/Desktop/mc-leaner.json
```

To apply cleanup actions (only when you are ready):

```bash
bash mc-leaner.sh --mode leftovers-only --apply
```

You will be prompted per item.

---

## What mc-leaner does NOT do

- No file deletion  
- No app uninstallation  
- No background agents or scheduled runs  
- No system “optimization”  
- No one-click cleaning  

---

## Documentation

Detailed behavior, guarantees, and design rationale live in `docs/`:

- `docs/FAQ.md` — common questions and edge cases
- `docs/SAFETY.md` — safety guarantees and non-interactive behavior
- `docs/README-FULL.md` — full, extended documentation
- `docs/ROADMAP.md` — planned direction and scope boundaries
- `docs/OUTPUT_SCHEMA.md` — JSON output contract

Project contracts and policies:

- `CHANGELOG.md` — release history
- `SECURITY.md` — vulnerability reporting policy
- `CONTRIBUTING.md` — how to contribute
- `CODING_STANDARDS.md` — contributor expectations and coding rules

The source code is the final authority.

---

## License and disclaimer

MIT License.  
This software is provided “as is”, without warranty of any kind.

You are responsible for reviewing and approving every action.
