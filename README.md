# mc-leaner

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

## What mc-leaner does (v2.1.0)

mc-leaner inspects macOS systems for:

- Startup and login items (launchd agents, daemons, login items)
- Orphaned or unmanaged launchd plists
- Large caches and logs
- Leftover data from uninstalled applications
- Large disk consumers with ownership attribution
- Intel-only executables on Apple Silicon (reporting only)
- Execution context and permission boundaries

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
  Restore by moving files back and rebooting if needed.

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
