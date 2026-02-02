#!/bin/bash
###############################################################################
# OpenClaw / ClawdBot / MoltBot - Complete Uninstall Script
# For use with Jamf Pro
# 
# This script detects, stops, and removes all components of:
#   - OpenClaw (current name)
#   - ClawdBot (legacy name)
#   - MoltBot (legacy name)
#
# Uses only macOS native binaries for detection and removal.
# THIS SCRIPT MAKES NO CHANGES TO THE SYSTEM.
#
# UPDATES:
#   - LOG_DIR must be configured before use (line 23)
#   - Enhanced brew detection with fallback to 'which brew' for non-standard paths
#   - Homebrew auto-updates suppressed during script execution
###############################################################################

# Exit on undefined variables
set -u

# Enable nullglob so that globs that match nothing expand to nothing
shopt -s nullglob

# Logging setup
LOG_DIR="SET_YOUR_LOG_LOCATION_HERE"  # e.g., /var/log/openclaw_detection
LOG_FILE="${LOG_DIR}/openclaw_uninstall.log"
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" | tee -a "$LOG_FILE"
}

log_section() {
    log "============================================"
    log "$1"
    log "============================================"
}

# Run as root check
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (via Jamf Pro)"
    exit 1
fi

log_section "Starting OpenClaw/ClawdBot/MoltBot Uninstall"

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

# Process names to kill
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
# Note: Profile-based directories (e.g., .openclaw-myprofile) are handled via pattern matching
CONFIG_DIRS=(
    ".openclaw"
    ".clawdbot"
    ".moltbot"
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

log "Found ${#LOCAL_USERNAMES[@]} local user(s): ${LOCAL_USERNAMES[*]}"

# Kill process by name (all instances)
kill_process() {
    local proc_name="$1"
    local pids
    pids=$(pgrep -x "$proc_name")
    if [[ -n "$pids" ]]; then
        log "Killing process: $proc_name (PIDs: $pids)"
        pkill -9 -x "$proc_name"
        return 0
    fi
    return 1
}

# Kill process by pattern
kill_process_pattern() {
    local pattern="$1"
    local pids
    pids=$(pgrep -f "$pattern")
    if [[ -n "$pids" ]]; then
        log "Killing processes matching: $pattern (PIDs: $pids)"
        pkill -9 -f "$pattern"
        return 0
    fi
    return 1
}

# Unload LaunchAgent for a specific user
unload_launchagent_for_user() {
    local user="$1"
    local home="$2"
    local plist="$3"
    local plist_path="$home/Library/LaunchAgents/$plist"
    local label="${plist%.plist}"
    
    if [[ -f "$plist_path" ]]; then
        log "Unloading LaunchAgent: $plist_path for user $user"
        local uid
        uid=$(id -u "$user")
        
        # Try bootout first (newer method, macOS 10.10+)
        if [[ -n "$uid" ]]; then
            if launchctl bootout "gui/$uid/$label"; then
                log "Successfully unloaded via bootout: gui/$uid/$label"
                return 0
            fi
        fi
        
        # Fall back to legacy unload if bootout fails
        if sudo -u "$user" launchctl unload -w "$plist_path"; then
            log "Successfully unloaded via legacy unload: $plist_path"
            return 0
        fi
        
        log "Warning: Could not unload $plist_path (may not be loaded)"
        return 0
    fi
    return 1
}

# Remove file/directory safely
safe_remove() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        log "Removing: $path"
        rm -rf "$path"
        return 0
    fi
    return 1
}

###############################################################################
# PHASE 0: TRY NATIVE UNINSTALLER FIRST
###############################################################################

log_section "Phase 0: Attempting native openclaw uninstall"

# Try to use the built-in uninstaller for each user if openclaw CLI is available
# Per documentation: https://docs.openclaw.ai/install/uninstall
# 1. openclaw gateway stop
# 2. openclaw gateway uninstall  
# 3. openclaw uninstall --all --yes --non-interactive

for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
    
    # Look for openclaw CLI in common locations
    openclaw_path=""
    for p in "$home/.npm-global/bin/openclaw" "$home/.local/share/pnpm/openclaw" "$home/.bun/bin/openclaw" /opt/homebrew/bin/openclaw /usr/local/bin/openclaw; do
        if [[ -x "$p" ]]; then
            openclaw_path="$p"
            break
        fi
    done
    
    # Also check if it's in user's PATH via nvm or similar
    if [[ -z "$openclaw_path" ]]; then
        openclaw_path=$(sudo -u "$username" which openclaw 2>/dev/null || true)
    fi
    
    if [[ -n "$openclaw_path" && -x "$openclaw_path" ]]; then
        log "Found openclaw CLI at $openclaw_path for user $username"
        
        # Step 1: Stop the gateway service
        log "Running: openclaw gateway stop"
        sudo -u "$username" "$openclaw_path" gateway stop 2>&1 | tee -a "$LOG_FILE" || true
        
        # Step 2: Uninstall the gateway service (launchd)
        log "Running: openclaw gateway uninstall"
        sudo -u "$username" "$openclaw_path" gateway uninstall 2>&1 | tee -a "$LOG_FILE" || true
        
        # Step 3: Full uninstall
        log "Running: openclaw uninstall --all --yes --non-interactive"
        if sudo -u "$username" "$openclaw_path" uninstall --all --yes --non-interactive 2>&1 | tee -a "$LOG_FILE"; then
            log "Native uninstall completed for user $username"
        else
            log "Native uninstall failed or partially completed for user $username, continuing with manual cleanup"
        fi
    fi
done

log "Proceeding with manual cleanup to ensure complete removal..."

###############################################################################
# PHASE 1: STOP ALL RUNNING PROCESSES AND SERVICES
###############################################################################

log_section "Phase 1: Stopping all processes and services"

# 1a. Stop LaunchAgents/LaunchDaemons for all users
log "Stopping LaunchAgents for all users..."
for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
    log "Processing user: $username ($home)"
    
    for plist in "${LAUNCHAGENT_PLISTS[@]}"; do
        unload_launchagent_for_user "$username" "$home" "$plist"
    done
    
    # Also check for any matching pattern (includes profile-based like bot.molt.myprofile.plist)
    for plist_file in "$home/Library/LaunchAgents"/*{openclaw,clawdbot,moltbot,bot.molt}*.plist; do
        if [[ -f "$plist_file" ]]; then
            plist_name=$(basename "$plist_file")
            unload_launchagent_for_user "$username" "$home" "$plist_name"
        fi
    done
done

# 1b. Stop system-level LaunchDaemons
log "Stopping system LaunchDaemons..."
for label in "${LAUNCHD_LABELS[@]}"; do
    if launchctl list "$label" &>/dev/null; then
        log "Unloading daemon: $label"
        # Try bootout first (newer method, macOS 10.10+)
        if launchctl bootout "system/$label"; then
            log "Successfully unloaded via bootout: system/$label"
        # Fall back to legacy unload if bootout fails
        elif launchctl unload -w "/Library/LaunchDaemons/${label}.plist"; then
            log "Successfully unloaded via legacy unload: $label"
        else
            log "Warning: Could not unload daemon $label"
        fi
    fi
done

# 1c. Kill all related processes
log "Killing all related processes..."
for proc in "${PROCESS_NAMES[@]}"; do
    kill_process "$proc"
done

# Kill by pattern (catches node processes running the gateway)
kill_process_pattern "openclaw"
kill_process_pattern "clawdbot"
kill_process_pattern "moltbot"
kill_process_pattern "openclaw-gateway"
kill_process_pattern "clawdbot-gateway"
kill_process_pattern "moltbot-gateway"

# 1d. Quit applications gracefully first, then force kill
log "Quitting applications..."
for app in "${APP_NAMES[@]}"; do
    if pgrep -x "$app" &>/dev/null; then
        osascript -e "tell application \"$app\" to quit"
        sleep 1
        kill_process "$app"
    fi
done

# Allow processes to terminate
sleep 2

###############################################################################
# PHASE 2: REMOVE APPLICATIONS
###############################################################################

log_section "Phase 2: Removing applications"

# 2a. Remove from /Applications
for app in "${APP_NAMES[@]}"; do
    safe_remove "/Applications/${app}.app"
done

# 2b. Remove from user Applications folders
for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
    for app in "${APP_NAMES[@]}"; do
        safe_remove "$home/Applications/${app}.app"
    done
done

# 2c. Remove any apps matching patterns in common locations
for dir in /Applications /Applications/Utilities; do
    for pattern in openclaw clawdbot moltbot; do
        for app in "$dir"/*"$pattern"*.app; do
            safe_remove "$app"
        done
    done
done

# 2d. Remove any apps matching patterns in user Applications folders
for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
    if [[ -d "$home/Applications" ]]; then
        for pattern in openclaw clawdbot moltbot; do
            for app in "$home/Applications"/*"$pattern"*.app; do
                safe_remove "$app"
            done
        done
    fi
done

###############################################################################
# PHASE 3: REMOVE LAUNCHAGENTS AND LAUNCHDAEMONS PLISTS
###############################################################################

log_section "Phase 3: Removing LaunchAgent/LaunchDaemon plists"

# 3a. Remove user LaunchAgents
for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
    
    for plist in "${LAUNCHAGENT_PLISTS[@]}"; do
        safe_remove "$home/Library/LaunchAgents/$plist"
    done
    
    # Pattern-based removal (includes profile-based plists like bot.molt.myprofile.plist)
    for pattern in openclaw clawdbot moltbot "bot.molt"; do
        for plist in "$home/Library/LaunchAgents"/*"$pattern"*.plist; do
            safe_remove "$plist"
        done
    done
done

# 3b. Remove system LaunchDaemons
for label in "${LAUNCHD_LABELS[@]}"; do
    safe_remove "/Library/LaunchDaemons/${label}.plist"
done

# Pattern-based removal for system daemons (includes bot.molt for profile-based labels)
for pattern in openclaw clawdbot moltbot "bot.molt"; do
    for plist in /Library/LaunchDaemons/*"$pattern"*.plist; do
        safe_remove "$plist"
    done
    for plist in /Library/LaunchAgents/*"$pattern"*.plist; do
        safe_remove "$plist"
    done
done

###############################################################################
# PHASE 4: REMOVE NPM/PNPM/BUN GLOBAL PACKAGES
###############################################################################

log_section "Phase 4: Removing npm/pnpm/bun global packages"

# Function to uninstall packages using native package managers for a user
uninstall_packages_native() {
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
    
    # Uninstall via npm
    if [[ -n "$npm_path" ]]; then
        log "Found npm at $npm_path for user $user"
        for pkg in "${NPM_PACKAGES[@]}"; do
            if sudo -u "$user" "$npm_path" list -g "$pkg" &>/dev/null; then
                log "Uninstalling $pkg via npm for $user"
                sudo -u "$user" "$npm_path" rm -g "$pkg"
            fi
        done
    fi
    
    # Uninstall via pnpm
    if [[ -n "$pnpm_path" ]]; then
        log "Found pnpm at $pnpm_path for user $user"
        for pkg in "${NPM_PACKAGES[@]}"; do
            if sudo -u "$user" "$pnpm_path" list -g "$pkg" &>/dev/null; then
                log "Uninstalling $pkg via pnpm for $user"
                sudo -u "$user" "$pnpm_path" remove -g "$pkg"
            fi
        done
    fi
    
    # Uninstall via bun
    if [[ -n "$bun_path" ]]; then
        log "Found bun at $bun_path for user $user"
        for pkg in "${NPM_PACKAGES[@]}"; do
            log "Attempting to uninstall $pkg via bun for $user"
            sudo -u "$user" "$bun_path" remove -g "$pkg"
        done
    fi
}

# Function to manually remove any remaining npm package files
cleanup_npm_packages_for_user() {
    local user="$1"
    local home="$2"
    
    for pkg in "${NPM_PACKAGES[@]}"; do
        # npm global (default location)
        if [[ -d "$home/.npm-global/lib/node_modules/$pkg" ]]; then
            log "Found remaining npm global package $pkg for $user"
            safe_remove "$home/.npm-global/lib/node_modules/$pkg"
            safe_remove "$home/.npm-global/bin/$pkg"
        fi
        
        # npm prefix (alternate location)
        if [[ -d "/usr/local/lib/node_modules/$pkg" ]]; then
            log "Found remaining npm package $pkg in /usr/local"
            safe_remove "/usr/local/lib/node_modules/$pkg"
            safe_remove "/usr/local/bin/$pkg"
        fi
        
        # pnpm global
        if [[ -d "$home/.local/share/pnpm/global/5/node_modules/$pkg" ]]; then
            log "Found remaining pnpm global package $pkg for $user"
            safe_remove "$home/.local/share/pnpm/global/5/node_modules/$pkg"
        fi
        for pnpm_global in "$home/Library/pnpm/global"/*"/node_modules/$pkg"; do
            if [[ -d "$pnpm_global" ]]; then
                log "Found remaining pnpm package: $pnpm_global"
                safe_remove "$pnpm_global"
            fi
        done
        
        # bun global
        if [[ -d "$home/.bun/install/global/node_modules/$pkg" ]]; then
            log "Found remaining bun global package $pkg for $user"
            safe_remove "$home/.bun/install/global/node_modules/$pkg"
        fi
        
        # Homebrew node modules
        for node_ver in /opt/homebrew/lib/node_modules /usr/local/lib/node_modules; do
            if [[ -d "$node_ver/$pkg" ]]; then
                log "Found remaining Homebrew node package: $node_ver/$pkg"
                safe_remove "$node_ver/$pkg"
            fi
        done
    done
    
    # Remove binaries from common locations
    for pkg in "${NPM_PACKAGES[@]}"; do
        safe_remove "$home/.npm-global/bin/$pkg"
        safe_remove "$home/.local/share/pnpm/$pkg"
        safe_remove "$home/.bun/bin/$pkg"
        safe_remove "/usr/local/bin/$pkg"
        safe_remove "/opt/homebrew/bin/$pkg"
    done
}

# Process all users - first try native uninstall, then manual cleanup
for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
    log "Processing npm/pnpm/bun packages for user: $username"
    
    # First: try native package manager uninstall
    uninstall_packages_native "$username" "$home"
    
    # Second: clean up any remaining files
    cleanup_npm_packages_for_user "$username" "$home"
done

###############################################################################
# PHASE 5: REMOVE HOMEBREW PACKAGES
###############################################################################

log_section "Phase 5: Removing Homebrew packages"

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

    # Prevent auto-updates during uninstall (only affects this script execution)
    export HOMEBREW_NO_AUTO_UPDATE=1
    
    # Determine the owner of the Homebrew installation
    brew_owner=$(stat -f '%Su' "$BREW_PATH")
    log "Homebrew owned by: $brew_owner"
    
    # First: Use native brew uninstall commands
    log "Attempting native Homebrew uninstall..."
    for formula in "${BREW_FORMULAS[@]}"; do
        # Check and uninstall formula
        if sudo -u "$brew_owner" "$BREW_PATH" list --formula "$formula" &>/dev/null; then
            log "Uninstalling Homebrew formula: $formula"
            sudo -u "$brew_owner" "$BREW_PATH" uninstall --force "$formula"
        fi
        
        # Check and uninstall cask
        if sudo -u "$brew_owner" "$BREW_PATH" list --cask "$formula" &>/dev/null; then
            log "Uninstalling Homebrew cask: $formula"
            sudo -u "$brew_owner" "$BREW_PATH" uninstall --cask --force "$formula"
        fi
    done
    
    # Also check for any other users who might have installed via Homebrew
    for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
        [[ "$username" == "$brew_owner" ]] && continue  # Already processed
        
        for formula in "${BREW_FORMULAS[@]}"; do
            if sudo -u "$username" "$BREW_PATH" list --formula "$formula" &>/dev/null 2>&1; then
                log "Uninstalling Homebrew formula: $formula (user: $username)"
                sudo -u "$username" "$BREW_PATH" uninstall --force "$formula"
            fi
            if sudo -u "$username" "$BREW_PATH" list --cask "$formula" &>/dev/null 2>&1; then
                log "Uninstalling Homebrew cask: $formula (user: $username)"
                sudo -u "$username" "$BREW_PATH" uninstall --cask --force "$formula"
            fi
        done
    done
else
    log "Homebrew not found, skipping native Homebrew uninstall"
fi

# Second: Clean up any remaining Homebrew Cellar/Caskroom remnants
log "Cleaning up any remaining Homebrew remnants..."
for formula in "${BREW_FORMULAS[@]}"; do
    safe_remove "/opt/homebrew/Cellar/$formula"
    safe_remove "/opt/homebrew/Caskroom/$formula"
    safe_remove "/usr/local/Cellar/$formula"
    safe_remove "/usr/local/Caskroom/$formula"
    # Also remove symlinks in bin
    safe_remove "/opt/homebrew/bin/$formula"
    safe_remove "/usr/local/bin/$formula"
done

###############################################################################
# PHASE 6: REMOVE CONFIGURATION AND DATA DIRECTORIES
###############################################################################

log_section "Phase 6: Removing configuration and data directories"

for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
    
    log "Removing config directories for user: $username"
    
    # Main config directories
    for config_dir in "${CONFIG_DIRS[@]}"; do
        safe_remove "$home/$config_dir"
    done
    
    # Profile-based config directories (e.g., .openclaw-myprofile, .moltbot-work)
    # Per documentation: profiles create state dirs like ~/.openclaw-<profile>
    for pattern in .openclaw-* .clawdbot-* .moltbot-*; do
        for dir in "$home"/$pattern; do
            safe_remove "$dir"
        done
    done
    
    # Application Support
    for app in "${APP_NAMES[@]}"; do
        safe_remove "$home/Library/Application Support/$app"
        safe_remove "$home/Library/Application Support/com.$app"
    done
    for pattern in openclaw clawdbot moltbot; do
        for dir in "$home/Library/Application Support"/*"$pattern"*; do
            safe_remove "$dir"
        done
    done
    
    # Caches
    for app in "${APP_NAMES[@]}"; do
        safe_remove "$home/Library/Caches/$app"
        safe_remove "$home/Library/Caches/com.$app"
    done
    for pattern in openclaw clawdbot moltbot; do
        for dir in "$home/Library/Caches"/*"$pattern"*; do
            safe_remove "$dir"
        done
    done
    
    # Preferences
    for bid in "${BUNDLE_IDS[@]}"; do
        safe_remove "$home/Library/Preferences/${bid}.plist"
    done
    for pattern in openclaw clawdbot moltbot; do
        for plist in "$home/Library/Preferences"/*"$pattern"*.plist; do
            safe_remove "$plist"
        done
    done
    
    # Saved Application State
    for bid in "${BUNDLE_IDS[@]}"; do
        safe_remove "$home/Library/Saved Application State/${bid}.savedState"
    done
    
    # Logs
    for app in "${APP_NAMES[@]}"; do
        safe_remove "$home/Library/Logs/$app"
    done
    for pattern in openclaw clawdbot moltbot; do
        for dir in "$home/Library/Logs"/*"$pattern"*; do
            safe_remove "$dir"
        done
    done
    
    # Containers (sandboxed apps)
    for bid in "${BUNDLE_IDS[@]}"; do
        safe_remove "$home/Library/Containers/$bid"
    done
    
    # Group Containers
    for pattern in openclaw clawdbot moltbot; do
        for dir in "$home/Library/Group Containers"/*"$pattern"*; do
            safe_remove "$dir"
        done
    done
    
    # HTTPStorages
    for bid in "${BUNDLE_IDS[@]}"; do
        safe_remove "$home/Library/HTTPStorages/$bid"
    done
    
    # WebKit data
    for bid in "${BUNDLE_IDS[@]}"; do
        safe_remove "$home/Library/WebKit/$bid"
    done
    
done

###############################################################################
# PHASE 7: REMOVE SYSTEM-LEVEL FILES AND RECEIPTS
###############################################################################

log_section "Phase 7: Removing system-level files and receipts"

# Package receipts - use pkgutil first
log "Removing package receipts via pkgutil..."
for pattern in openclaw clawdbot moltbot; do
    # Find all matching package IDs
    while IFS= read -r pkg_id; do
        [[ -z "$pkg_id" ]] && continue
        log "Forgetting package receipt: $pkg_id"
        pkgutil --forget "$pkg_id"
    done < <(pkgutil --pkgs | grep -i "$pattern")
done

# Fallback: manually remove any remaining receipts in /var/db/receipts
log "Cleaning up any remaining receipt files..."
for pattern in openclaw clawdbot moltbot; do
    for receipt in /var/db/receipts/*"$pattern"*.bom /var/db/receipts/*"$pattern"*.plist; do
        safe_remove "$receipt"
    done
done

# Private var directories
for pattern in openclaw clawdbot moltbot; do
    for dir in /private/var/folders/*/*/"$pattern"*; do
        safe_remove "$dir"
    done
done

# Temporary files
for pattern in openclaw clawdbot moltbot; do
    for tmpfile in /tmp/*"$pattern"*; do
        safe_remove "$tmpfile"
    done
    for tmpfile in /private/tmp/*"$pattern"*; do
        safe_remove "$tmpfile"
    done
done

###############################################################################
# PHASE 8: FINAL VERIFICATION AND CLEANUP
###############################################################################

log_section "Phase 8: Final verification"

# Verify all processes are stopped
remaining_procs=0
for proc in "${PROCESS_NAMES[@]}"; do
    if pgrep -x "$proc" &>/dev/null; then
        log "WARNING: Process still running: $proc"
        remaining_procs=$((remaining_procs + 1))
    fi
done

# Check for remaining files
remaining_files=0
for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
    for config_dir in "${CONFIG_DIRS[@]}"; do
        if [[ -d "$home/$config_dir" ]]; then
            log "WARNING: Config directory still exists: $home/$config_dir"
            remaining_files=$((remaining_files + 1))
        fi
    done
done

# Check for remaining apps
for app in "${APP_NAMES[@]}"; do
    if [[ -d "/Applications/${app}.app" ]]; then
        log "WARNING: Application still exists: /Applications/${app}.app"
        remaining_files=$((remaining_files + 1))
    fi
done

###############################################################################
# SUMMARY
###############################################################################

log_section "Uninstall Complete"

if [[ $remaining_procs -eq 0 && $remaining_files -eq 0 ]]; then
    log "SUCCESS: All OpenClaw/ClawdBot/MoltBot components have been removed."
    exit 0
else
    log "PARTIAL: Uninstall completed with warnings."
    log "  - Remaining processes: $remaining_procs"
    log "  - Remaining files/directories: $remaining_files"
    log "Please review the log at $LOG_FILE for details."
    exit 0
fi
