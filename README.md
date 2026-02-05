# remediate-OpenClaw

# OpenClaw/ClawdBot/MoltBot Detection and Removal Scripts

A pair of comprehensive bash scripts for detecting and removing OpenClaw, ClawdBot, and MoltBot components from macOS systems. Designed for use with Jamf Pro but can be adapted for standalone use.

## Scripts

### `detect_openclaw_public.sh`
Read-only detection script that scans for all traces of OpenClaw/ClawdBot/MoltBot without making any system changes. Logs all findings for review.

### `uninstall_openclaw_public.sh`
Complete removal script that stops services, uninstalls packages, and cleans up all configuration files and directories.

### `openclaw_detection_log_EA.sh`
Optional Extention Attribute for Jamf Pro. Looks at the last few lines of the log file to determine if anything was found.

## Features

- **Comprehensive Detection**: Scans for applications, LaunchAgents/LaunchDaemons, npm/pnpm/bun packages, Homebrew formulas, configuration directories, and more
- **Multi-User Support**: Processes all local user accounts (UID ≥ 501)
- **Native Uninstallers First**: Attempts to use built-in uninstall commands before manual cleanup
- **Enhanced Brew Detection**: Automatically finds Homebrew in standard locations or via PATH
- **Safe Execution**: Uses only macOS native binaries for maximum compatibility
- **Detailed Logging**: Creates comprehensive logs of all actions and findings
- **Profile-Aware**: Handles profile-based installations (e.g., `.openclaw-myprofile`)

## Requirements

- Root privileges (designed to run via Jamf Pro or with `sudo`)
- Bash shell

## Configuration

**Before running either script**, you must configure the log directory:

Edit line 28 in both scripts and set your desired log location:

```bash
LOG_DIR="SET_YOUR_LOG_LOCATION_HERE"  # e.g., /var/log/openclaw_detection
