# JSON Output Schema

This document defines the JSON summary contract for mc-leaner.

## Schema version

- `schema_version`: `"1"`

## Top-level shape

```json
{
  "meta": {
    "version": "2.5.0",
    "schema_version": "1",
    "mode": "scan",
    "apply": false,
    "explain": false,
    "startup_system": false,
    "backup_dir": "/Users/.../McLeaner_Backups_YYYYMMDD_HHMMSS",
    "quiet": false,
    "gui_prompts": "auto",
    "allow_sudo": false,
    "thresholds_mb": {
      "caches": 200,
      "logs": 50,
      "leftovers": 50,
      "disk": 200
    },
    "json": true
  },
  "privacy": {
    "total_services": 0,
    "unknown_services": 0,
    "network_facing": 0
  },
  "summary": {
    "module_lines": [],
    "action_lines": [],
    "info_lines": [],
    "legacy_lines": []
  },
  "records": [
    {"type": "service", "raw": "SERVICE? ..."},
    {"type": "disk", "raw": "DISK? ..."},
    {"type": "other", "raw": "..."}
  ]
}
```

## Field notes

- `meta.version` is read from `VERSION`.
- `meta.schema_version` is a stable contract identifier.
- `records[].raw` preserves machine-readable records exactly as emitted.
- `summary.legacy_lines` mirrors the classic run summary entries.
- Array ordering is stable but not semantically meaningful.
