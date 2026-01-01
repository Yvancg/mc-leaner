# Security Policy

## Supported Versions

mc-leaner is currently in early but stable development.

Security-related fixes apply only to the **latest released version**.
Older versions are not actively supported.

---

## Reporting a Security Issue

If you believe you have found a **security vulnerability** in mc-leaner, please report it responsibly.

### How to report

- **Do not** open a public GitHub issue for security-sensitive findings.
- Instead, contact the maintainer directly.

**Preferred contact:**
- Email: security@mc-leaner.dev  
  (or open a private GitHub security advisory if enabled)

When reporting, please include:
- macOS version
- Apple Silicon or Intel
- mc-leaner version or commit hash
- Exact command used
- Description of the issue and potential impact

---

## What qualifies as a security issue

Security issues may include:
- Privilege escalation vulnerabilities
- Unsafe use of `sudo`
- Insecure file handling (symlink attacks, path traversal)
- Command injection possibilities
- Unintended modification of protected system areas

---

## What does NOT qualify as a security issue

The following are **not** considered security vulnerabilities:
- False positives in orphan detection
- Disagreements about cleanup heuristics
- User-approved removal of files
- Breakage caused by ignoring safety prompts

These should be reported as normal issues instead.

---

## Security design notes

mc-leaner is designed to reduce risk by:
- Never deleting files
- Requiring explicit user approval for every action
- Avoiding background services or persistent privileges
- Limiting `sudo` usage to file moves only, when required

The attack surface is intentionally kept small.

---

## Disclosure policy

- Valid security reports will be acknowledged as soon as possible.
- Fixes will be prioritized over feature work.
- Public disclosure will occur only after a fix is available, or by mutual agreement.

---

## Final note

mc-leaner is a local maintenance tool, not a networked service.

Most risks arise from misuse rather than exploitation.  
If you are unsure, use dry-run mode and inspect results carefully.
