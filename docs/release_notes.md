mc-leaner v2.3.0 — Release Notes

Focus: accuracy, explainability, and service visibility across background services, bins, and disk correlation.
Safety: inspection-first. No behavior changes to cleaning defaults.

⸻

What’s new

1. Script shim awareness in /usr/local/bin

Problem: Valid launcher scripts were sometimes flagged as orphans, or hard to diagnose when stale.
Solution:
	•	Detect small shebang-based script shims.
	•	Extract referenced .app bundle paths.
	•	If the app exists → treated as managed.
	•	If the app is missing → flagged as a likely stale shim.

Big win:
In --explain, script shims now always log the extracted bundle path, even when the app exists. This makes it obvious whether failures come from extraction or from a missing app.

⸻

2. Robust symlink resolution

Problem: Common editor CLIs and app-provided binaries are symlinks into app bundles.
Solution:
	•	Canonical, physical symlink resolution via shared fs helpers.
	•	Existing targets are treated as managed and skipped.
	•	Prevents false positives for tools like code, cursor, etc.

⸻

3. Inventory-first bin attribution

Problem: /usr/local/bin heuristics alone are noisy.
Solution:
	•	Inventory index keys are used as a fast membership guard.
	•	When inventory is missing, behavior falls back to heuristics with explicit logging.

⸻

4. Cleaner, more explainable logs
	•	Redacted temp paths unless --explain is enabled.
	•	Explicit explain logs for:
	•	Script shim detection
	•	Missing app classification
	•	Inventory fallback paths
	•	Consistent summary exports even when nothing is flagged.

⸻

5. Timing model stabilized

Problem: Partial runs made per-module timing confusing.
Solution:
	•	Unrun modules report 0s.
	•	Total time always reflects wall-clock runtime.
	•	No placeholders, no colored markers, no conditional formatting.

⸻

Internal improvements (no behavior change)
	•	Centralized filesystem logic in lib/fs.sh (symlink + shim parsing).
	•	Reduced per-file work by short-circuiting script-shim detection to likely candidates only.
	•	Strict-mode hardening where safe; explicit fallbacks where strict mode would break inspection.

⸻

Compatibility and safety
	•	Fully backward-compatible with v2.2.x.
	•	No changes to default behavior.
	•	No deletions without --apply and per-item confirmation.

⸻

Upgrade notes

No migration required.
Recommended to run once with:

mc-leaner --mode bins-only --explain

to see the new script shim and symlink diagnostics in action.

⸻

v2.3.0 summary:
Fewer false positives, clearer explanations, and tighter internals—without changing what the tool is allowed to do.
