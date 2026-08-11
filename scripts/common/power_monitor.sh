#!/bin/bash
# ==============================================================================
# Script Name: power_monitor.sh
# Description: Monitor notebook power status and initiate a graceful shutdown
#              when on battery power and the capacity falls below safety threshold.
#              Supports custom modular shutdown scripts and prevents duplicate triggers.
#              Uses native Systemd shutdown status, PID tracking, and a warm-reboot
#              self-healing sequence when power is restored mid-process.
# ==============================================================================

# Safe battery capacity threshold (percentage)
SAFE_THRESHOLD=40

# Native Systemd scheduled shutdown state file
SYSTEMD_SHUTDOWN_FILE="/run/systemd/shutdown/scheduled"
LOG_FILE="/var/log/power_monitor.log"
SHUTDOWN_SCRIPTS_DIR="/etc/power_monitor.d"
HOOK_PIDS_FILE="/run/power_monitor_hooks.pids"

# Maximum time to wait for the custom hooks before rebooting on power restore.
# Must exceed the slowest hook: stopping SAP HANA can take far longer than a few
# minutes, and rebooting while "HDB stop" is still running would crash-stop the
# database - which a log_mode=overwrite instance cannot roll forward from.
HOOK_WAIT_TIMEOUT=3600

# Locate the battery: not every ThinkPad exposes it as BAT0 (BAT1 is common too,
# and multi-battery models number them differently). Hardcoding BAT0 would make
# this script exit early on those machines and silently disable all protection.
BAT_PATH=""
for candidate in /sys/class/power_supply/BAT*; do
    if [ -r "$candidate/status" ] && [ -r "$candidate/capacity" ]; then
        BAT_PATH="$candidate"
        break
    fi
done

if [ -z "$BAT_PATH" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: No battery found under /sys/class/power_supply/BAT*." >> "$LOG_FILE"
    exit 1
fi

# Read battery status and current capacity
BAT_STATUS=$(cat "$BAT_PATH/status" 2>/dev/null)
BAT_CAPACITY=$(cat "$BAT_PATH/capacity" 2>/dev/null)

# Exit if battery files cannot be read
if [ -z "$BAT_STATUS" ] || [ -z "$BAT_CAPACITY" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Cannot read battery status or capacity from $BAT_PATH." >> "$LOG_FILE"
    exit 1
fi

# Guard against a non-numeric capacity: the comparisons below would otherwise
# abort the script with a syntax error and skip the shutdown entirely.
case "$BAT_CAPACITY" in
    ''|*[!0-9]*)
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Battery capacity '$BAT_CAPACITY' is not numeric." >> "$LOG_FILE"
        exit 1 ;;
esac

# ------------------------------------------------------------------------------
# Case A: Systemd Shutdown is already in progress (scheduled shutdown file exists)
# ------------------------------------------------------------------------------
if [ -f "$SYSTEMD_SHUTDOWN_FILE" ]; then
    # Self-healing check: If power is restored (no longer discharging), cancel shutdown
    # and wait for active hooks to finish BEFORE rebooting to prevent DB corruption!
    if [ "$BAT_STATUS" != "Discharging" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [Self-Healing] Power Restored: Battery status is '$BAT_STATUS'." >> "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [Self-Healing] Cancelling scheduled system shutdown immediately to block power-off." >> "$LOG_FILE"
        
        # 1. Cancel the OS shutdown first to ensure the machine stays powered on
        if command -v shutdown &>/dev/null; then
            shutdown -c "Power restored. Safe rebooting sequence initiated." >> "$LOG_FILE" 2>&1
        fi
        
        # 2. Wait for any active custom shutdown scripts to finish gracefully
        if [ -f "$HOOK_PIDS_FILE" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [Self-Healing] Active hooks detected. Waiting for database/application flushes..." >> "$LOG_FILE"
            timeout=$HOOK_WAIT_TIMEOUT
            while [ $timeout -gt 0 ]; do
                any_running=false
                # Check each PID from the tracking file
                while read -r pid; do
                    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                        any_running=true
                        break
                    fi
                done < "$HOOK_PIDS_FILE"
                
                if [ "$any_running" = false ]; then
                    break
                fi
                
                sleep 5
                timeout=$((timeout - 5))
            done
            rm -f "$HOOK_PIDS_FILE"
            if [ "$any_running" = true ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - [Self-Healing] WARNING: Hooks still running after ${HOOK_WAIT_TIMEOUT}s. Rebooting anyway - a database may be stopped hard!" >> "$LOG_FILE"
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') - [Self-Healing] All running hooks have completed gracefully." >> "$LOG_FILE"
            fi
        fi
        
        # 3. Safe system warm-reboot to cleanly restart all systemd services in correct order
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [Self-Healing] Power is stable and hooks are done. Executing reboot to cleanly restart services." >> "$LOG_FILE"
        /sbin/reboot
    else
        # Still discharging, just exit quietly to prevent duplicate triggers
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Info: System is already on an 11-minute graceful shutdown countdown. Exiting." >> "$LOG_FILE"
    fi
    exit 0
fi

# ------------------------------------------------------------------------------
# Case B: Low-power condition detected (Discharging AND below threshold)
# ------------------------------------------------------------------------------
if [ "$BAT_STATUS" = "Discharging" ] && [ "$BAT_CAPACITY" -lt "$SAFE_THRESHOLD" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - WARNING: Power outage detected (Discharging). Battery level ($BAT_CAPACITY%) is below safe threshold ($SAFE_THRESHOLD%)." >> "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Initiating 11-minute graceful shutdown sequence." >> "$LOG_FILE"
    
    # Clear any stale PIDs file
    rm -f "$HOOK_PIDS_FILE"
    
    # Step 1: Execute custom modular shutdown scripts in the background and track PIDs
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Scanning for modular shutdown hooks in $SHUTDOWN_SCRIPTS_DIR..." >> "$LOG_FILE"
    if [ -d "$SHUTDOWN_SCRIPTS_DIR" ]; then
        shopt -s nullglob
        for script in "$SHUTDOWN_SCRIPTS_DIR"/*; do
            if [ -x "$script" ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - [Dispatcher] Triggering custom hook: $script" >> "$LOG_FILE"
                # Run the hook in its own session (setsid) so that it survives the
                # teardown of this cron job's login session. With
                # logind KillUserProcesses=yes, plain background children would be
                # SIGKILLed the moment this script exits - killing "HDB stop" halfway.
                if command -v setsid >/dev/null 2>&1; then
                    setsid "$script" >> "$LOG_FILE" 2>&1 &
                else
                    "$script" >> "$LOG_FILE" 2>&1 &
                fi
                # Store the spawned background process PID for precise tracking
                echo $! >> "$HOOK_PIDS_FILE"
            fi
        done
        shopt -u nullglob
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Info: Custom scripts directory $SHUTDOWN_SCRIPTS_DIR does not exist. Skipping hooks." >> "$LOG_FILE"
    fi
    
    # Step 2: Force sync filesystem caches to prevent corruption
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Syncing file systems..." >> "$LOG_FILE"
    sync && sync
    
    # Step 3: Execute system shutdown with an 11-minute delay (leaving a 1-minute safety window for the 10th-minute cron run)
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Scheduling operating system shutdown in 11 minutes..." >> "$LOG_FILE"
    if command -v shutdown &>/dev/null; then
        shutdown -h +11 "Power outage warning: battery level is low ($BAT_CAPACITY%). System will shut down in 11 minutes. Custom services are stopping." >> "$LOG_FILE" 2>&1
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: 'shutdown' command not found. Cannot schedule system shutdown." >> "$LOG_FILE"
    fi
fi
