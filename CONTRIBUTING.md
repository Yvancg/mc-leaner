# Contributing to mc-leaner

Thank you for your interest in contributing to **mc-leaner**.

This project prioritizes **safety, clarity, and reversibility** over feature velocity. Please read this document carefully before proposing changes.

---

## Open source and contribution scope

mc-leaner follows an **open-core model**.

This repository contains the **core inspection engine** and is intended to remain fully open source:

- inspection logic
- safety rules
- decision-making code
- reporting and explainability

Contributions to this repository should focus on improving the **core**, not on building product layers.

Future commercial components (such as GUI, packaging, distribution, or support tooling) will live outside this repository and are **out of scope** here.

Contributing to mc-leaner means contributing to transparency, correctness, and user trust.

---

## Core principles (non-negotiable)

These principles define the functional contract of mc-leaner.

Any change that violates them is considered a **bug**, not a stylistic disagreement.
Violations must be treated as functional regressions and fixed accordingly.
Pull requests that break these principles will be rejected or reverted.

All contributions must respect these principles:

1. **Safe by default**
   - New functionality must default to dry-run or reporting-only.
   - No destructive actions without explicit user opt-in.

2. **No silent behavior**
   - Every action must be visible, logged, and explainable.
   - No background services, no daemons, no auto-runs.

3. **Reversible**
   - No deletions.
   - All cleanup actions must move items to a recoverable backup location.

4. **User control**
   - Users choose what modules run.
   - No “smart cleanup” or bundled automation.

If a proposed feature violates any of the above, it will not be accepted.

---

## What contributions are welcome

- New **modules** that follow the project safety model
- Improvements to existing detection heuristics (with clear rationale)
- Documentation improvements (README, SAFETY, FAQ)
- Bug fixes and edge-case handling
- Better reporting and summaries
- Test cases and reproducible scenarios

---

## What is explicitly out of scope

- Automatic deletion of files
- “One-click clean” behavior
- Performance tuning, RAM cleaners, or cache purging without inspection
- Closed-source dependencies
- GUI-only workflows that hide logic

---

## Project structure expectations

All new functionality should be implemented as a **module** under `modules/` and must expose:

```bash
module_name="example"
module_description="Short description"

module_run() {
  # main logic
}

module_report() {
  # optional summary
}
```

Shared logic belongs in `lib/`, not duplicated across modules.

---

## How to contribute

1. Fork the repository
2. Create a feature branch:

   ```bash
   git checkout -b feature/my-change
   ```

3. Make your changes
4. Ensure:
   - Shell scripts remain compatible with Bash 3.2
   - No GNU-only utilities without fallbacks
   - No destructive behavior by default
5. Update documentation if behavior changes
6. Open a pull request with:
   - clear explanation of the change
   - reasoning for safety impact
   - example output (dry-run)

---

## Code style

- Prefer clarity over cleverness
- Avoid deeply nested logic
- Comment intent, not mechanics
- Defensive checks are encouraged

---

## Review process

Pull requests will be reviewed with a strong bias toward:

- safety
- explicitness
- long-term maintainability

If a change increases risk without a clear, user-visible benefit, it will likely be rejected.

---

## Reporting issues

When opening an issue, include:

- macOS version
- Apple Silicon or Intel
- command used
- whether it was a dry-run or apply
- exact output or error message

---

By contributing, you agree that mc-leaner is a **maintenance tool**, not an optimizer.
