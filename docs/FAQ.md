# FAQ

## Is mc-leaner safe?

Yes, by design.

mc-leaner is **safe by default**:

- It runs in dry-run mode unless you explicitly use `--apply`
- It never deletes files
- All changes are reversible via a backup folder
- Security and endpoint protection software is always skipped

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

## What does the Caches module actually do?

The Caches module is **inspection-first**.

It scans user-level cache locations and highlights **large cache directories** based on conservative size thresholds. For each cache group, it reports:

- total size
- last modification time
- owning app (best-effort)
- largest subfolders (with `--explain`)

By default, nothing is moved or removed.

If you use `--apply`, mc-leaner will:
- prompt you per cache group
- move selected caches to a backup folder
- never delete anything

This allows you to safely reclaim space without guessing.

---

## What does the Logs module do, and is it safe?

The Logs module inspects **large log files and directories** (default threshold: 50MB).

It scans:
- `~/Library/Logs`
- `/Library/Logs`
- `/var/log`

By default, it only reports:
- size
- last modified time
- related log rotations
- top subfolders for large directories

With `--apply`, logs can be relocated to a backup folder **only after explicit confirmation**.

No logs are ever deleted automatically.
---

## Does mc-leaner work on Apple Silicon?

Yes.

mc-leaner is fully compatible with Apple Silicon Macs. One of its features is reporting **Intel-only executables** so you can decide whether legacy software is still worth keeping.

---

## Why doesn’t mc-leaner delete files automatically?

Because deletion is irreversible.

mc-leaner is built around:

- reversibility
- transparency
- user intent

Automatic deletion would violate all three.

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
