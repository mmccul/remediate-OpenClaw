#!/bin/bash
###############################################################################
# OpenClaw Detection Log Analysis - False Positive Detection (Improved)
# 
# This script checks if npm/pnpm detections were false positives by:
# 1. Checking if ONLY package manager packages were detected (no other evidence)
# 2. Checking if uninstall showed errors or patterns indicating packages weren't installed:
#    - pnpm: ERR_PNPM_NO_IMPORTER_MANIFEST_FOUND error
#    - npm: "up to date, audited" pattern (indicates nothing was uninstalled)
# 3. Checking if anything was actually removed during uninstall
#
# Exit codes:
#   0 = Genuine detection (found other evidence or files were removed)
#   1 = False positive detection
###############################################################################

# set -x

LOG_DIR="SET_YOUR_LOG_LOCATION_HERE"  # e.g., /var/log/openclaw_detection
DETECT_LOG="${LOG_DIR}/openclaw_detection.log"
UNINSTALL_LOG="${LOG_DIR}/openclaw_uninstall.log"

echo "=== OpenClaw False Positive Analysis ==="

# Check if logs exist
if [[ ! -f "$DETECT_LOG" ]]; then
    echo "Detection log not found at $DETECT_LOG"
    exit 0
fi

# Count total detections
TOTAL_FOUND=$(grep -c "^\\[.*\\] FOUND:" "$DETECT_LOG" 2>/dev/null) || TOTAL_FOUND=0
PNPM_FOUND=$(grep -c "FOUND: pnpm global package:" "$DETECT_LOG" 2>/dev/null) || PNPM_FOUND=0
NPM_FOUND=$(grep -c "FOUND: npm global package:" "$DETECT_LOG" 2>/dev/null) || NPM_FOUND=0
PACKAGE_MANAGER_FOUND=$((PNPM_FOUND + NPM_FOUND))
OTHER_EVIDENCE_FOUND=$((TOTAL_FOUND - PACKAGE_MANAGER_FOUND))

echo "Detection Summary:"
echo "  Total items found: $TOTAL_FOUND"
echo "  pnpm packages found: $PNPM_FOUND"
echo "  npm packages found: $NPM_FOUND"
echo "  Other evidence found: $OTHER_EVIDENCE_FOUND"

# Collect uninstall data
echo ""
echo "Checking uninstall results..."

if [[ ! -f "$UNINSTALL_LOG" ]]; then
    echo "  WARNING: Uninstall log not found"
    REMOVED_COUNT=0
    UNINSTALLING_COUNT=0
    HAS_PNPM_ERROR=false
    HAS_NPM_NO_REMOVAL=false
else
    REMOVED_COUNT=$(grep -c "^\\[.*\\] Removing:" "$UNINSTALL_LOG" 2>/dev/null) || REMOVED_COUNT=0
    UNINSTALLING_COUNT=$(grep -c "^\\[.*\\] Uninstalling" "$UNINSTALL_LOG" 2>/dev/null) || UNINSTALLING_COUNT=0
    
    # Check for pnpm error indicating package wasn't really installed
    if grep -q "ERR_PNPM_NO_IMPORTER_MANIFEST_FOUND" "$UNINSTALL_LOG"; then
        HAS_PNPM_ERROR=true
    else
        HAS_PNPM_ERROR=false
    fi
    
    # Check for npm "up to date, audited" which indicates nothing was uninstalled
    if grep -q "up to date, audited.*package" "$UNINSTALL_LOG"; then
        HAS_NPM_NO_REMOVAL=true
    else
        HAS_NPM_NO_REMOVAL=false
    fi
fi

echo "Uninstall Summary:"
echo "  Items removed: $REMOVED_COUNT"
echo "  Uninstall attempts: $UNINSTALLING_COUNT"
echo "  PNPM error found: $HAS_PNPM_ERROR"
echo "  NPM no-removal pattern: $HAS_NPM_NO_REMOVAL"

# Decision logic based on all collected data
echo ""
echo "=== Analysis ==="

# If actual files were removed, it was genuine regardless of what was detected
if [[ $REMOVED_COUNT -gt 0 ]]; then
    echo "GENUINE DETECTION:"
    echo "  - Files were actually removed ($REMOVED_COUNT items)"
    exit 0
fi

# If non-package-manager evidence was found, it's genuine (even if nothing was removed)
if [[ $OTHER_EVIDENCE_FOUND -gt 0 ]]; then
    echo "GENUINE DETECTION:"
    echo "  - Found evidence beyond just package manager packages"
    echo "  - However, nothing was removed during uninstall (may need investigation)"
    exit 0
fi

# If only package manager packages detected with confirmation they weren't installed
if [[ $PACKAGE_MANAGER_FOUND -gt 0 ]]; then
    # pnpm with error confirms false positive
    if [[ $PNPM_FOUND -gt 0 ]] && [[ $HAS_PNPM_ERROR == true ]]; then
        echo "FALSE POSITIVE CONFIRMED:"
        echo "  - Only pnpm packages detected ($PNPM_FOUND)"
        echo "  - PNPM error confirms packages were never actually installed"
        exit 1
    fi
    
    # npm with "up to date" pattern indicates false positive
    if [[ $NPM_FOUND -gt 0 ]] && [[ $HAS_NPM_NO_REMOVAL == true ]] && [[ $REMOVED_COUNT -eq 0 ]]; then
        echo "FALSE POSITIVE CONFIRMED:"
        echo "  - Only npm packages detected ($NPM_FOUND)"
        echo "  - NPM output indicates packages were never actually installed"
        exit 1
    fi
    
    # Package manager packages detected but nothing removed (likely false positive)
    if [[ $REMOVED_COUNT -eq 0 ]]; then
        echo "LIKELY FALSE POSITIVE:"
        echo "  - Only package manager packages detected (pnpm: $PNPM_FOUND, npm: $NPM_FOUND)"
        echo "  - Nothing was actually removed during uninstall"
        exit 1
    fi
fi

# If nothing detected and nothing removed, no evidence of installation
if [[ $TOTAL_FOUND -eq 0 ]] && [[ $REMOVED_COUNT -eq 0 ]]; then
    echo "NO DETECTION:"
    echo "  - No evidence found during detection"
    echo "  - Nothing removed during uninstall"
    exit 1
fi

# Edge case: Nothing detected but something was removed
# (This shouldn't happen but handle it as genuine)
echo "UNUSUAL CASE:"
echo "  - Detection found: $TOTAL_FOUND items"
echo "  - Items removed: $REMOVED_COUNT"
echo "  - Treating as genuine due to uncertainty"
exit 0