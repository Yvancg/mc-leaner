# mc-leaner

Safe, interactive Mac Cleaner for launchd plists (LaunchAgents/LaunchDaemons) and typical Intel leftovers.

This tool moves suspected orphaned items to a timestamped backup folder on your Desktop instead of deleting them.

## What it does

- Scans:
  - /Library/LaunchAgents
  - /Library/LaunchDaemons
  - ~/Library/LaunchAgents
- Skips:
  - active launchctl jobs
  - known security tools (Bitdefender, Malwarebytes)
  - Homebrew service labels (homebrew.mxcl.*) if enabled in the script
- Offers a GUI prompt for every move.
- Writes a report of Intel-only executables to ~/Desktop/intel_binaries.txt

## What it does NOT do

- It does not delete files.
- It does not uninstall apps.
- It does not modify app bundles.

## Safety rules

1. Do not remove security software daemons unless you are intentionally uninstalling that product.
2. Prefer uninstalling apps normally before removing their launchd plists.
3. Always reboot after moving system daemons to confirm everything still works.
4. If something breaks, restore the plist from the backup folder and reboot.

## Requirements

- macOS
- bash (macOS default is fine)
- osascript (built-in)
- launchctl (built-in)
- Homebrew (optional)

## Proposed Structure

```tree
- mc-leaner/
├── mc-leaner.sh              # Entry point (CLI dispatcher)
├── modules/
│   ├── launchd.sh            # LaunchAgents / LaunchDaemons (current)
│   ├── bins.sh               # /usr/local/bin orphan checks
│   ├── intel.sh              # Intel-only binary report
│   ├── caches.sh             # User/system cache inspection (future)
│   ├── brew.sh               # Homebrew hygiene (future)
│   ├── leftovers.sh          # App uninstall leftovers (future)
│   ├── logs.sh               # Log growth inspection (future)
│   └── permissions.sh        # Suspicious permissions audit (future)
├── lib/
│   ├── cli.sh                # Arg parsing, usage, help
│   ├── ui.sh                 # GUI + terminal prompts
│   ├── fs.sh                 # Safe move, sudo detection
│   ├── safety.sh             # Hard skip rules
│   └── utils.sh              # Shared helpers
├── config/
│   ├── skip-labels.conf      # Security / protected labels
│   ├── skip-paths.conf       # Never-touch paths
│   └── modes.conf            # Mode → module mapping
├── docs/
│   ├── ROADMAP.md
│   ├── MODULES.md
│   ├── SAFETY.md
│   └── FAQ.md
├── assets/
│   └── social-preview.png
├── README.md
└── LICENSE
```

## Usage

```bash
bash orphan_cleaner.sh
```

## Restore

Move items back from the backup folder to their original locations and reboot.

## Disclaimer

Use at your own risk. This project is provided with no warranty.
