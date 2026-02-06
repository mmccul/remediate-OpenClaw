#!/bin/bash
###############################################################################
# OpenClaw / ClawdBot / MoltBot - Detection Script (Read-Only)
# For use with Jamf Pro
# 
# This script DETECTS (but does not remove) all components of:
#   - OpenClaw (current name)
#   - ClawdBot (legacy name)
#   - MoltBot (legacy name)
#
# Uses only macOS native binaries for detection.
# THIS SCRIPT MAKES NO CHANGES TO THE SYSTEM.
#
# UPDATES:
#   - LOG_DIR must be configured before use (line 28)
#   - Enhanced brew detection with fallback to 'which brew' for non-standard paths
#   - Homebrew auto-updates suppressed during script execution
#   - Fixed logging of zero local users to avoid empty output
###############################################################################

# Exit on undefined variables
set -u

# Enable nullglob so that globs that match nothing expand to nothing
shopt -s nullglob

# Logging setup
LOG_DIR="SET_YOUR_LOG_LOCATION_HERE"  # e.g., /var/log/openclaw_detection
LOG_FILE="${LOG_DIR}/openclaw_detection.log"
mkdir -p "$LOG_DIR"

# Detection counters
TOTAL_FOUND=0

log() {
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" | tee -a "$LOG_FILE"
}

log_section() {
    log "============================================"
    log "$1"
    log "============================================"
}

log_found() {
    log "FOUND: $1"
    TOTAL_FOUND=$((TOTAL_FOUND + 1))
}

# Run as root check
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (via Jamf Pro)"
    exit 1
fi

log_section "Starting OpenClaw/ClawdBot/MoltBot Detection (Read-Only)"

###############################################################################
# CONFIGURATION - All known identifiers and paths
###############################################################################

# Application names (all variations)
APP_NAMES=(
    "OpenClaw"
    "ClawdBot"
    "MoltBot"
)

# Bundle identifiers for apps
BUNDLE_IDS=(
    "com.openclaw.app"
    "com.openclaw.gateway"
    "com.clawdbot.app"
    "com.clawdbot.gateway"
    "bot.molt.app"
    "bot.molt.gateway"
    "ai.openclaw.app"
    "ai.openclaw.gateway"
)

# LaunchAgent/LaunchDaemon identifiers
LAUNCHD_LABELS=(
    "com.openclaw.gateway"
    "com.openclaw.app"
    "com.clawdbot.gateway"
    "com.clawdbot.app"
    "bot.molt.gateway"
    "bot.molt.app"
)

# LaunchAgent plist filenames (user-level)
LAUNCHAGENT_PLISTS=(
    "com.openclaw.gateway.plist"
    "com.openclaw.app.plist"
    "com.clawdbot.gateway.plist"
    "com.clawdbot.app.plist"
    "bot.molt.gateway.plist"
    "bot.molt.app.plist"
)

# npm/pnpm/bun package names
NPM_PACKAGES=(
    "openclaw"
    "moltbot"
    "clawdbot"
)

# Homebrew formula names
BREW_FORMULAS=(
    "openclaw"
    "openclaw-cli"
    "clawdbot"
    "clawdbot-cli"
    "moltbot"
    "moltbot-cli"
)

# Process names to check
PROCESS_NAMES=(
    "openclaw"
    "OpenClaw"
    "clawdbot"
    "ClawdBot"
    "moltbot"
    "MoltBot"
    "openclaw-gateway"
    "clawdbot-gateway"
    "moltbot-gateway"
)

# Config directory names (in user home)
CONFIG_DIRS=(
    ".openclaw"
    ".clawdbot"
    ".moltbot"
)

# Profile-based config directory prefixes (e.g., .openclaw-myprofile)
PROFILE_PREFIXES=(
    ".openclaw-"
    ".clawdbot-"
    ".moltbot-"
)

###############################################################################
# HELPER FUNCTIONS
###############################################################################

# Populate arrays of local users (excluding system accounts, UID >= 501)
# Run once at startup for efficiency
LOCAL_USERNAMES=()
LOCAL_USERHOMES=()

while IFS= read -r username; do
    uid=$(dscl . read /Users/"$username" UniqueID 2>/dev/null | awk '{print $2}')
    if [[ -n "$uid" && "$uid" -ge 501 ]]; then
        home=$(dscl . read /Users/"$username" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        if [[ -d "$home" ]]; then
            LOCAL_USERNAMES+=("$username")
            LOCAL_USERHOMES+=("$home")
        fi
    fi
done < <(dscl . list /Users)

log "Found ${#LOCAL_USERNAMES[@]} local user(s): ${LOCAL_USERNAMES[*]:-}"

# Check if file/directory exists
check_path() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        log_found "$path"
        return 0
    fi
    return 1
}

###############################################################################
# PHASE 1: DETECT RUNNING PROCESSES AND SERVICES
###############################################################################

log_section "Phase 1: Detecting running processes and services"

# 1a. Check for running processes
log "Checking for running processes..."
for proc in "${PROCESS_NAMES[@]}"; do
    pids=$(pgrep -x "$proc")
    if [[ -n "$pids" ]]; then
        log_found "Running process: $proc (PIDs: $pids)"
    fi
done

# Check by pattern (catches node processes running the gateway)
for pattern in openclaw clawdbot moltbot; do
    pids=$(pgrep -f "$pattern")
    if [[ -n "$pids" ]]; then
        log_found "Running process matching pattern '$pattern' (PIDs: $pids)"
    fi
done

# 1b. Check loaded LaunchAgents for all users
log "Checking loaded LaunchAgents for all users..."
for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
    
    uid=$(id -u "$username")
    [[ -z "$uid" ]] && continue
    
    for label in "${LAUNCHD_LABELS[@]}"; do
        if launchctl print "gui/$uid/$label" &>/dev/null; then
            log_found "Loaded LaunchAgent: $label for user $username"
        fi
    done
    
    # Pattern-based check (includes bot.molt for profile-based labels)
    for pattern in openclaw clawdbot moltbot bot.molt; do
        while IFS= read -r loaded_label; do
            [[ -z "$loaded_label" ]] && continue
            if [[ "$loaded_label" == *"$pattern"* ]]; then
                log_found "Loaded LaunchAgent matching '$pattern': $loaded_label for user $username"
            fi
        done < <(launchctl print "gui/$uid" 2>/dev/null | grep -i "$pattern" | awk '{print $NF}')
    done
done

# 1c. Check loaded system LaunchDaemons
log "Checking loaded system LaunchDaemons..."
for label in "${LAUNCHD_LABELS[@]}"; do
    if launchctl list "$label" &>/dev/null; then
        log_found "Loaded LaunchDaemon: $label"
    fi
done

###############################################################################
# PHASE 2: DETECT APPLICATIONS
###############################################################################

log_section "Phase 2: Detecting applications"

# 2a. Check /Applications
for app in "${APP_NAMES[@]}"; do
    check_path "/Applications/${app}.app"
done

# 2b. Check user Applications folders
for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
    for app in "${APP_NAMES[@]}"; do
        check_path "$home/Applications/${app}.app"
    done
done

# 2c. Check for apps matching patterns in common locations
for dir in /Applications /Applications/Utilities; do
    for pattern in openclaw clawdbot moltbot; do
        for app in "$dir"/*"$pattern"*.app; do
            check_path "$app"
        done
    done
done

# 2d. Check for apps matching patterns in user Applications folders
for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
    if [[ -d "$home/Applications" ]]; then
        for pattern in openclaw clawdbot moltbot; do
            for app in "$home/Applications"/*"$pattern"*.app; do
                check_path "$app"
            done
        done
    fi
done

###############################################################################
# PHASE 3: DETECT LAUNCHAGENT AND LAUNCHDAEMON PLISTS
###############################################################################

log_section "Phase 3: Detecting LaunchAgent/LaunchDaemon plists"

# 3a. Check user LaunchAgents
for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
    
    for plist in "${LAUNCHAGENT_PLISTS[@]}"; do
        check_path "$home/Library/LaunchAgents/$plist"
    done
    
    # Pattern-based check (includes bot.molt for profile-based labels)
    for pattern in openclaw clawdbot moltbot "bot.molt"; do
        for plist in "$home/Library/LaunchAgents"/*"$pattern"*.plist; do
            check_path "$plist"
        done
    done
done

# 3b. Check system LaunchDaemons
for label in "${LAUNCHD_LABELS[@]}"; do
    check_path "/Library/LaunchDaemons/${label}.plist"
done

# Pattern-based check for system daemons (includes bot.molt for profile-based labels)
for pattern in openclaw clawdbot moltbot "bot.molt"; do
    for plist in /Library/LaunchDaemons/*"$pattern"*.plist; do
        check_path "$plist"
    done
    for plist in /Library/LaunchAgents/*"$pattern"*.plist; do
        check_path "$plist"
    done
done

###############################################################################
# PHASE 4: DETECT NPM/PNPM/BUN GLOBAL PACKAGES
###############################################################################

log_section "Phase 4: Detecting npm/pnpm/bun global packages"

# Function to detect packages using native package managers for a user
detect_packages_native() {
    local user="$1"
    local home="$2"
    
    # Find npm
    local npm_path=""
    for p in "$home/.nvm/versions/node"/*/bin/npm /opt/homebrew/bin/npm /usr/local/bin/npm /usr/bin/npm; do
        if [[ -x "$p" ]]; then
            npm_path="$p"
            break
        fi
    done
    
    # Find pnpm
    local pnpm_path=""
    for p in "$home/.local/share/pnpm/pnpm" "$home/Library/pnpm/pnpm" /opt/homebrew/bin/pnpm /usr/local/bin/pnpm; do
        if [[ -x "$p" ]]; then
            pnpm_path="$p"
            break
        fi
    done
    
    # Find bun
    local bun_path=""
    for p in "$home/.bun/bin/bun" /opt/homebrew/bin/bun /usr/local/bin/bun; do
        if [[ -x "$p" ]]; then
            bun_path="$p"
            break
        fi
    done
    
    # Check npm
    if [[ -n "$npm_path" ]]; then
        log "Found npm at $npm_path for user $user"
        # NOTE: `npm list -g <pkg>` may return exit code 0 even when <pkg> is NOT installed,
        # which can create false positives if we only check the exit status.
        # Prefer checking the global root directory and confirming the package path exists.
        npm_global_root="$(sudo -u "$user" "$npm_path" root -g 2>/dev/null | tr -d '\r' || true)"
        if [[ -n "$npm_global_root" ]]; then
            log "npm global root for user $user: $npm_global_root"
            for pkg in "${NPM_PACKAGES[@]}"; do
                if [[ -e "$npm_global_root/$pkg" || -L "$npm_global_root/$pkg" ]]; then
                    log_found "npm global package: $pkg (user: $user)"
                fi
            done
        else
            # Fallback: parse output for an actual "<name>@<version>" occurrence.
            for pkg in "${NPM_PACKAGES[@]}"; do
                npm_out="$(sudo -u "$user" "$npm_path" list -g --depth 0 "$pkg" 2>/dev/null || true)"
                if echo "$npm_out" | grep -Eiq "(^|[[:space:]])${pkg}@"; then
                    log_found "npm global package: $pkg (user: $user)"
                fi
            done
        fi
    fi
    
    # Check pnpm
    if [[ -n "$pnpm_path" ]]; then
        log "Found pnpm at $pnpm_path for user $user"
        # NOTE: `pnpm list -g <pkg>` may return exit code 0 even when <pkg> is NOT installed,
        # which can create false positives if we only check the exit status.
        # Prefer checking the global root directory and confirming the package path exists.
        pnpm_global_root="$(sudo -u "$user" "$pnpm_path" root -g 2>/dev/null | tr -d '\r' || true)"
        if [[ -n "$pnpm_global_root" ]]; then
            log "pnpm global root for user $user: $pnpm_global_root"
            for pkg in "${NPM_PACKAGES[@]}"; do
                if [[ -e "$pnpm_global_root/$pkg" || -L "$pnpm_global_root/$pkg" ]]; then
                    log_found "pnpm global package: $pkg (user: $user)"
                fi
            done
        else
            # Fallback: parse output for an actual "<name>@<version>" occurrence.
            for pkg in "${NPM_PACKAGES[@]}"; do
                pnpm_out="$(sudo -u "$user" "$pnpm_path" list -g --depth 0 "$pkg" 2>/dev/null || true)"
                if echo "$pnpm_out" | grep -Eiq "(^|[[:space:]])${pkg}@"; then
                    log_found "pnpm global package: $pkg (user: $user)"
                fi
            done
        fi
    fi
    
    # Check bun
    if [[ -n "$bun_path" ]]; then
        log "Found bun at $bun_path for user $user"
        for pkg in "${NPM_PACKAGES[@]}"; do
            if sudo -u "$user" "$bun_path" pm ls -g | grep -q "$pkg"; then
                log_found "bun global package: $pkg (user: $user)"
            fi
        done
    fi
}

# Function to check for package files directly
detect_npm_package_files() {
    local user="$1"
    local home="$2"
    
    for pkg in "${NPM_PACKAGES[@]}"; do
        # npm global (default location)
        check_path "$home/.npm-global/lib/node_modules/$pkg"
        
        # npm prefix (alternate location)
        check_path "/usr/local/lib/node_modules/$pkg"
        
        # pnpm global
        check_path "$home/.local/share/pnpm/global/5/node_modules/$pkg"
        for pnpm_global in "$home/Library/pnpm/global"/*"/node_modules/$pkg"; do
            check_path "$pnpm_global"
        done
        
        # bun global
        check_path "$home/.bun/install/global/node_modules/$pkg"
        
        # Homebrew node modules
        check_path "/opt/homebrew/lib/node_modules/$pkg"
        check_path "/usr/local/lib/node_modules/$pkg"
    done
    
    # Check for binaries
    for pkg in "${NPM_PACKAGES[@]}"; do
        check_path "$home/.npm-global/bin/$pkg"
        check_path "$home/.local/share/pnpm/$pkg"
        check_path "$home/.bun/bin/$pkg"
        check_path "/usr/local/bin/$pkg"
        check_path "/opt/homebrew/bin/$pkg"
    done
}

# Process all users
for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
    log "Checking npm/pnpm/bun packages for user: $username"
    
    detect_packages_native "$username" "$home"
    detect_npm_package_files "$username" "$home"
done

###############################################################################
# PHASE 5: DETECT HOMEBREW PACKAGES
###############################################################################

log_section "Phase 5: Detecting Homebrew packages"

# Find Homebrew installation
BREW_PATH=""
if [[ -x "/opt/homebrew/bin/brew" ]]; then
    BREW_PATH="/opt/homebrew/bin/brew"
elif [[ -x "/usr/local/bin/brew" ]]; then
    BREW_PATH="/usr/local/bin/brew"
else
    # Fallback: try to find brew using which
    BREWBIN=$(which brew 2>/dev/null)
    if [[ -n "${BREWBIN}" ]]; then
        BREW_PATH=${BREWBIN}
    fi
fi

if [[ -n "$BREW_PATH" ]]; then
    log "Found Homebrew at: $BREW_PATH"

    # Prevent auto-updates during list (only affects this script execution)
    export HOMEBREW_NO_AUTO_UPDATE=1
    
    # Determine the owner of the Homebrew installation
    brew_owner=$(stat -f '%Su' "$BREW_PATH")
    log "Homebrew owned by: $brew_owner"
    
    # Check for installed formulas and casks
    for formula in "${BREW_FORMULAS[@]}"; do
        if sudo -u "$brew_owner" "$BREW_PATH" list --formula "$formula" &>/dev/null; then
            log_found "Homebrew formula: $formula"
        fi
        
        if sudo -u "$brew_owner" "$BREW_PATH" list --cask "$formula" &>/dev/null; then
            log_found "Homebrew cask: $formula"
        fi
    done
else
    log "Homebrew not found"
fi

# Check for Homebrew Cellar/Caskroom remnants
for formula in "${BREW_FORMULAS[@]}"; do
    check_path "/opt/homebrew/Cellar/$formula"
    check_path "/opt/homebrew/Caskroom/$formula"
    check_path "/usr/local/Cellar/$formula"
    check_path "/usr/local/Caskroom/$formula"
    check_path "/opt/homebrew/bin/$formula"
    check_path "/usr/local/bin/$formula"
done

###############################################################################
# PHASE 6: DETECT CONFIGURATION AND DATA DIRECTORIES
###############################################################################

log_section "Phase 6: Detecting configuration and data directories"

for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
    
    log "Checking config directories for user: $username"
    
    # Main config directories
    for config_dir in "${CONFIG_DIRS[@]}"; do
        check_path "$home/$config_dir"
    done
    
    # Profile-based config directories (e.g., .openclaw-myprofile)
    for prefix in "${PROFILE_PREFIXES[@]}"; do
        for profile_dir in "$home"/"${prefix}"*; do
            check_path "$profile_dir"
        done
    done
    
    # Application Support
    for app in "${APP_NAMES[@]}"; do
        check_path "$home/Library/Application Support/$app"
        check_path "$home/Library/Application Support/com.$app"
    done
    for pattern in openclaw clawdbot moltbot; do
        for dir in "$home/Library/Application Support"/*"$pattern"*; do
            check_path "$dir"
        done
    done
    
    # Caches
    for app in "${APP_NAMES[@]}"; do
        check_path "$home/Library/Caches/$app"
        check_path "$home/Library/Caches/com.$app"
    done
    for pattern in openclaw clawdbot moltbot; do
        for dir in "$home/Library/Caches"/*"$pattern"*; do
            check_path "$dir"
        done
    done
    
    # Preferences
    for bid in "${BUNDLE_IDS[@]}"; do
        check_path "$home/Library/Preferences/${bid}.plist"
    done
    for pattern in openclaw clawdbot moltbot; do
        for plist in "$home/Library/Preferences"/*"$pattern"*.plist; do
            check_path "$plist"
        done
    done
    
    # Saved Application State
    for bid in "${BUNDLE_IDS[@]}"; do
        check_path "$home/Library/Saved Application State/${bid}.savedState"
    done
    
    # Logs
    for app in "${APP_NAMES[@]}"; do
        check_path "$home/Library/Logs/$app"
    done
    for pattern in openclaw clawdbot moltbot; do
        for dir in "$home/Library/Logs"/*"$pattern"*; do
            check_path "$dir"
        done
    done
    
    # Containers (sandboxed apps)
    for bid in "${BUNDLE_IDS[@]}"; do
        check_path "$home/Library/Containers/$bid"
    done
    
    # Group Containers
    for pattern in openclaw clawdbot moltbot; do
        for dir in "$home/Library/Group Containers"/*"$pattern"*; do
            check_path "$dir"
        done
    done
    
    # HTTPStorages
    for bid in "${BUNDLE_IDS[@]}"; do
        check_path "$home/Library/HTTPStorages/$bid"
    done
    
    # WebKit data
    for bid in "${BUNDLE_IDS[@]}"; do
        check_path "$home/Library/WebKit/$bid"
    done
    
done

###############################################################################
# PHASE 7: DETECT SYSTEM-LEVEL FILES AND RECEIPTS
###############################################################################

log_section "Phase 7: Detecting system-level files and receipts"

# Package receipts via pkgutil
log "Checking package receipts via pkgutil..."
for pattern in openclaw clawdbot moltbot; do
    while IFS= read -r pkg_id; do
        [[ -z "$pkg_id" ]] && continue
        log_found "Package receipt: $pkg_id"
    done < <(pkgutil --pkgs | grep -i "$pattern")
done

# Check for receipt files directly
for pattern in openclaw clawdbot moltbot; do
    for receipt in /var/db/receipts/*"$pattern"*.bom /var/db/receipts/*"$pattern"*.plist; do
        check_path "$receipt"
    done
done

# Private var directories
for pattern in openclaw clawdbot moltbot; do
    for dir in /private/var/folders/*/*/"$pattern"*; do
        check_path "$dir"
    done
done

# Temporary files
for pattern in openclaw clawdbot moltbot; do
    for tmpfile in /tmp/*"$pattern"*; do
        check_path "$tmpfile"
    done
    for tmpfile in /private/tmp/*"$pattern"*; do
        check_path "$tmpfile"
    done
done

###############################################################################
# SUMMARY
###############################################################################

log_section "Detection Complete"

if [[ $TOTAL_FOUND -eq 0 ]]; then
    log "RESULT: No OpenClaw/ClawdBot/MoltBot components detected."
    log "The system appears clean."
    exit 0
else
    log "RESULT: Detected $TOTAL_FOUND OpenClaw/ClawdBot/MoltBot component(s)."
    log "Review the log at $LOG_FILE for details."
    log ""
    log "To remove these components, run the uninstall script."
    # Optionally call jamf policy directly if anything detected
    # log "Running the uninstall policy..."
    # jamf policy -event uninstall_openclaw
    exit 0
fi
