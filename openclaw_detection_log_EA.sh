#!/bin/bash

# ===================================================================================
# Script Name:   openclaw_detection_log_EA.sh
# Description:   Checks the last few lines of the OpenClaw detection log for results 
#                as a Jamf Pro EA
# Author:        David West-Talarek (charliwest)
# Created Date:  2026-02-03
# License:       MIT
# Disclaimer:    This script is provided "as is" without warranty of any kind.
#                Use at your own risk.
# ===================================================================================

# Path to the log file defined in the detection script
LOG_DIR="SET_YOUR_LOG_LOCATION_HERE"  # e.g., /var/log/openclaw_detection

# Check if the log file exists
if [[ -f "$LOG_DIR" ]]; then
    # Read the last 10 lines of the log file
    # grep -q returns true (0) if the pattern is found
    if tail -n 10 "$LOG_DIR" | grep -q "RESULT: Detected"; then
        echo "<result>Detected</result>"
    else
        # Log exists, but "RESULT: Detected" was not found in the tail
        # This implies "RESULT: No OpenClaw..." was the last output
        echo "<result>Not Detected</result>"
    fi
else
    # The log file does not exist, meaning the detection script hasn't run yet
    echo "<result>Log Not Found</result>"
fi
