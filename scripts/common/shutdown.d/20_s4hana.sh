#!/bin/bash
# ==============================================================================
# Script Name: 20_s4hana.sh
# Description: Modular shutdown hook for a SAP S/4HANA system (ABAP application
#              server + SAP HANA database) running on this ThinkPad server.
#              Triggered by scripts/common/power_monitor.sh when the machine runs
#              on battery below the safe threshold.
#
#              IMPORTANT - this HANA instance runs with log_mode = overwrite:
#              there are no log backups, so a crashed database can only be
#              recovered from its savepoint plus the redo log volume - there is
#              no roll-forward from log backups. Therefore this hook NEVER kills
#              the database. Instead it keeps postponing the operating system
#              shutdown until "HDB stop" has really finished, and only then
#              powers the machine off (which also saves battery).
#
#              Shutdown order follows SAP's documented sequence:
#                1. Stop the ABAP/Java application instances  (sapcontrol StopSystem)
#                2. Wait until every instance is really GRAY   (GetProcessList)
#                3. Stop the HANA database and WAIT for it     (HDB stop)
#                   - extending the OS shutdown deadline while it runs
#                4. Verify, sync, then power off
#
#              Manual equivalent (as reference):
#                su - <sid>adm    -c "sapcontrol -nr <nr> -function StopSystem ALL"
#                su - <sid>adm    -c "sapcontrol -nr <nr> -function GetProcessList"
#                su - <hdbsid>adm -c "HDB stop"
#                su - <hdbsid>adm -c "HDB info"
#
# Deployment:  sudo cp 20_s4hana.sh /etc/power_monitor.d/ && sudo chmod +x /etc/power_monitor.d/20_s4hana.sh
# Test run:    sudo /etc/power_monitor.d/20_s4hana.sh      (see DRY_RUN below)
# ==============================================================================

# ------------------------------------------------------------------------------
# Configuration (override in /etc/sysconfig/power_monitor_s4hana if needed)
# ------------------------------------------------------------------------------
CONF_FILE="/etc/sysconfig/power_monitor_s4hana"

# Instance lists in "SID:NR" form, space separated. Leave empty for auto-detection
# from the /usr/sap/<SID>/<INSTANCE><NR> directory layout.
#   Example: SAP_ABAP_INSTANCES="CHD:01"
#            SAP_HANA_INSTANCES="DBC:00"
SAP_ABAP_INSTANCES=""
SAP_HANA_INSTANCES=""

ABAP_STOP_TIMEOUT=300       # seconds to wait for the application servers to go GRAY
HANA_STOP_TIMEOUT=3600      # hard upper bound for "HDB stop" (battery floor hits first)
POLL_INTERVAL=10            # status polling interval in seconds

# Application servers may be terminated hard on timeout: open transactions are
# simply rolled back by the database, which is a normal DB operation.
FORCE_STOP_ABAP_ON_TIMEOUT=1

# --- Deadline management ------------------------------------------------------
# power_monitor.sh schedules "shutdown -h +11". Because log_mode = overwrite we
# must not let that deadline cut power while HANA is still stopping, so this hook
# keeps pushing the deadline forward as long as the database is making progress.
KEEP_ALIVE_UNTIL_STOPPED=1  # 1 = postpone the OS shutdown while HANA is stopping
EXTEND_MINUTES=10           # each extension pushes the shutdown this far out
EXTEND_THRESHOLD=180        # extend once less than this many seconds remain

# Absolute floor: below this battery level the machine is about to lose power
# anyway, so we stop waiting and let the OS shut down in an orderly fashion
# (systemd stops the sapinit/HANA services, then syncs and powers off).
CRITICAL_BATTERY=8

# Power off as soon as the database is confirmed down - no reason to sit on the
# remaining battery. Skipped automatically if AC power came back in the meantime,
# so that power_monitor.sh's self-healing reboot can take over instead.
POWEROFF_WHEN_DONE=1

DRY_RUN=0                   # 1 = log the intended actions only, change nothing

# Shared with s4hana_start.sh so that a start can never overlap with this stop
LOCK_FILE="/run/s4hana_control.lock"
SYSTEMD_SHUTDOWN_FILE="/run/systemd/shutdown/scheduled"
BATTERY_PATH="/sys/class/power_supply/BAT0"
HOSTCTRL_SAPCONTROL="/usr/sap/hostctrl/exe/sapcontrol"

[ -r "$CONF_FILE" ] && . "$CONF_FILE"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [S4HANA] $*"
}

# Run a command as the given SAP OS user with a login shell so that the
# <sid>adm profile (PATH, DIR_LIBRARY, LD_LIBRARY_PATH, ...) is in effect.
run_as() {
    local user="$1" timeout_s="$2" cmd="$3"
    timeout --signal=TERM --kill-after=30 "$timeout_s" su - "$user" -c "$cmd" 2>&1
}

# sapcontrol wrapper: prefers the <sid>adm PATH, falls back to the host agent binary.
sapctl() {
    local adm="$1" nr="$2" timeout_s="$3"; shift 3
    local out rc
    out=$(run_as "$adm" "$timeout_s" "sapcontrol -nr $nr -function $*"); rc=$?
    if [ "$rc" -eq 127 ] && [ -x "$HOSTCTRL_SAPCONTROL" ]; then
        out=$(run_as "$adm" "$timeout_s" "$HOSTCTRL_SAPCONTROL -nr $nr -function $*"); rc=$?
    fi
    printf '%s\n' "$out"
    return $rc
}

# True when no instance process is running any more.
# sapcontrol GetProcessList returns 3 when all processes are GREEN and 4 when all
# are GRAY; an unreachable sapstartsrv (no GREEN/YELLOW in the output) also means
# the instance is down.
instance_is_stopped() {
    local adm="$1" nr="$2" out rc
    out=$(sapctl "$adm" "$nr" 60 GetProcessList); rc=$?
    [ "$rc" -eq 4 ] && return 0
    printf '%s' "$out" | grep -qE 'GREEN|YELLOW' && return 1
    return 0
}

# Derive the SAP OS user from a SID: CHD -> chdadm
adm_user() {
    echo "$(echo "$1" | tr '[:upper:]' '[:lower:]')adm"
}

battery_capacity() {
    cat "$BATTERY_PATH/capacity" 2>/dev/null
}

battery_status() {
    cat "$BATTERY_PATH/status" 2>/dev/null
}

# 0 = power is about to run out, stop waiting for a graceful stop
battery_is_critical() {
    local cap status
    cap=$(battery_capacity)
    status=$(battery_status)
    [ -n "$cap" ] || return 1                  # unreadable battery: keep waiting
    [ "$status" = "Discharging" ] || return 1  # on AC: keep waiting
    [ "$cap" -lt "$CRITICAL_BATTERY" ]
}

# Seconds left until the scheduled systemd poweroff (empty if none scheduled).
os_shutdown_remaining() {
    local usec now
    [ -r "$SYSTEMD_SHUTDOWN_FILE" ] || return 1
    usec=$(sed -n 's/^USEC=//p' "$SYSTEMD_SHUTDOWN_FILE" | head -1)
    [ -n "$usec" ] || return 1
    now=$(date +%s)
    echo $(( usec / 1000000 - now ))
}

# Push the OS shutdown deadline out while the database is still stopping.
# systemd's ScheduleShutdown overwrites an existing schedule, so no "shutdown -c"
# is needed - avoiding a window in which power_monitor.sh could re-trigger.
keep_deadline_alive() {
    [ "$KEEP_ALIVE_UNTIL_STOPPED" -eq 1 ] || return 0
    command -v shutdown >/dev/null 2>&1 || return 0

    local remaining
    remaining=$(os_shutdown_remaining) || return 0
    [ "$remaining" -lt "$EXTEND_THRESHOLD" ] || return 0

    if [ "$DRY_RUN" -eq 1 ]; then
        log "[DRY-RUN] Would extend the OS shutdown deadline by +${EXTEND_MINUTES} min (${remaining}s left)."
        return 0
    fi
    if shutdown -h "+$EXTEND_MINUTES" \
        "SAP HANA is still shutting down (log_mode=overwrite: no forced kill). Power off postponed." \
        >/dev/null 2>&1; then
        log "OS shutdown deadline had ${remaining}s left - extended to +${EXTEND_MINUTES} min."
    else
        log "Warning: Could not extend the OS shutdown deadline (${remaining}s left)."
    fi
}

# ------------------------------------------------------------------------------
# Auto-detection of installed instances via /usr/sap/<SID>/<INSTANCE><NR>
# ------------------------------------------------------------------------------
detect_instances() {
    local sid_dir sid inst_dir inst
    shopt -s nullglob
    for sid_dir in /usr/sap/*/; do
        sid=$(basename "$sid_dir")
        # Skip non-SID directories of the SAP file system layout
        case "$sid" in
            hostctrl|trans|tmp|put|ccms|SYS) continue ;;
        esac
        [ ${#sid} -eq 3 ] || continue

        for inst_dir in "$sid_dir"*/; do
            inst=$(basename "$inst_dir")
            [ -d "$inst_dir/exe" ] || [ -d "$inst_dir/work" ] || continue
            case "$inst" in
                HDB[0-9][0-9])
                    SAP_HANA_INSTANCES="$SAP_HANA_INSTANCES $sid:${inst#HDB}" ;;
                DVEBMGS[0-9][0-9]|ASCS[0-9][0-9]|SCS[0-9][0-9]|ERS[0-9][0-9]|D[0-9][0-9]|J[0-9][0-9]|W[0-9][0-9]|G[0-9][0-9]|SMDA[0-9][0-9])
                    # Strip the instance type prefix, keeping the 2-digit number
                    SAP_ABAP_INSTANCES="$SAP_ABAP_INSTANCES $sid:${inst##*[A-Z]}" ;;
            esac
        done
    done
    shopt -u nullglob
}

# ------------------------------------------------------------------------------
# Single-run guard: the dispatcher may fire again on the next cron tick
# ------------------------------------------------------------------------------
exec 9>"$LOCK_FILE" || exit 1
if ! flock -n 9; then
    log "Info: Another S/4HANA shutdown hook is already running. Exiting."
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    log "Error: This hook must run as root (it switches to the <sid>adm users)."
    exit 1
fi

if [ -z "$SAP_ABAP_INSTANCES$SAP_HANA_INSTANCES" ]; then
    detect_instances
fi

# Normalise whitespace
SAP_ABAP_INSTANCES=$(echo "$SAP_ABAP_INSTANCES" | xargs)
SAP_HANA_INSTANCES=$(echo "$SAP_HANA_INSTANCES" | xargs)

if [ -z "$SAP_ABAP_INSTANCES$SAP_HANA_INSTANCES" ]; then
    log "Info: No SAP instance found under /usr/sap. Nothing to stop."
    exit 0
fi

log "Power event received. Starting graceful S/4HANA shutdown."
log "Application instances : ${SAP_ABAP_INSTANCES:-none}"
log "Database instances    : ${SAP_HANA_INSTANCES:-none}"
log "HANA log_mode=overwrite -> forced kill disabled, OS shutdown will be postponed until stopped."
log "Battery: $(battery_capacity)% ($(battery_status)), critical floor ${CRITICAL_BATTERY}%."
[ "$DRY_RUN" -eq 1 ] && log "DRY-RUN mode: no service will actually be stopped."

EXIT_CODE=0
HANA_ALL_STOPPED=1
ABORTED_CRITICAL=0

# ------------------------------------------------------------------------------
# Step 1: Stop the ABAP/Java application servers
#         StopSystem stops the whole SAP system of that SID in the correct order
#         (dialog instances first, then ERS/ASCS), so one call per SID is enough.
#         The HANA database has its own SID and is therefore not affected here.
# ------------------------------------------------------------------------------
pending=""
if [ -n "$SAP_ABAP_INSTANCES" ]; then
    for sid in $(for e in $SAP_ABAP_INSTANCES; do echo "${e%%:*}"; done | sort -u); do
        adm=$(adm_user "$sid")
        # Lowest instance number of this SID is used to talk to sapstartsrv
        nr=$(for e in $SAP_ABAP_INSTANCES; do [ "${e%%:*}" = "$sid" ] && echo "${e##*:}"; done | sort | head -1)

        if ! id "$adm" >/dev/null 2>&1; then
            log "Warning: OS user $adm does not exist. Skipping SID $sid."
            continue
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            log "[DRY-RUN] Would run: su - $adm -c 'sapcontrol -nr $nr -function StopSystem ALL'"
            continue
        fi
        log "Stopping SAP system $sid via instance $nr (sapcontrol StopSystem ALL)..."
        sapctl "$adm" "$nr" 120 StopSystem ALL | sed "s/^/    [$sid] /"
    done

    # Wait until every application instance has really terminated
    log "Waiting up to ${ABAP_STOP_TIMEOUT}s for the application servers to stop..."
    elapsed=0
    while [ "$DRY_RUN" -eq 0 ] && [ "$elapsed" -lt "$ABAP_STOP_TIMEOUT" ]; do
        pending=""
        for e in $SAP_ABAP_INSTANCES; do
            sid="${e%%:*}"; nr="${e##*:}"
            adm=$(adm_user "$sid")
            id "$adm" >/dev/null 2>&1 || continue
            instance_is_stopped "$adm" "$nr" || pending="$pending $sid/$nr"
        done
        [ -z "$pending" ] && break
        log "Still running:$pending (${elapsed}s/${ABAP_STOP_TIMEOUT}s)"
        keep_deadline_alive
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    if [ -n "$pending" ]; then
        log "Warning: Application instances did not stop in time:$pending"
        if [ "$FORCE_STOP_ABAP_ON_TIMEOUT" -eq 1 ]; then
            for e in $pending; do
                sid="${e%%/*}"; nr="${e##*/}"
                adm=$(adm_user "$sid")
                log "Forcing termination of $sid instance $nr (open transactions will be rolled back)..."
                sapctl "$adm" "$nr" 60 StopWait 60 5 | sed "s/^/    [$sid] /"
                pkill -TERM -u "$adm" 2>/dev/null
            done
            sleep 10
        fi
        EXIT_CODE=1
    elif [ "$DRY_RUN" -eq 0 ]; then
        log "All SAP application instances are stopped."
    fi
fi

# ------------------------------------------------------------------------------
# Step 2: Stop the SAP HANA database and WAIT for it
#         "HDB stop" writes a final savepoint and waits for the processes to end.
#         It runs in the background here only so that this script stays awake to
#         push the OS shutdown deadline forward and to watch the battery floor.
#         There is deliberately NO kill path for the database (log_mode=overwrite).
# ------------------------------------------------------------------------------
for e in $SAP_HANA_INSTANCES; do
    sid="${e%%:*}"; nr="${e##*:}"
    adm=$(adm_user "$sid")

    if ! id "$adm" >/dev/null 2>&1; then
        log "Warning: OS user $adm does not exist. Skipping HANA SID $sid."
        HANA_ALL_STOPPED=0
        EXIT_CODE=1
        continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "[DRY-RUN] Would run: su - $adm -c 'HDB stop' and wait for completion."
        continue
    fi

    log "Stopping HANA database $sid (instance $nr) as $adm: HDB stop..."
    STOP_OUT=$(mktemp /run/power_monitor_s4hana_XXXXXX)
    run_as "$adm" "$HANA_STOP_TIMEOUT" "HDB stop" > "$STOP_OUT" 2>&1 &
    stop_pid=$!

    waited=0
    aborted=0
    while kill -0 "$stop_pid" 2>/dev/null; do
        if battery_is_critical; then
            log "ERROR: Battery dropped to $(battery_capacity)% (floor ${CRITICAL_BATTERY}%) while HANA $sid was still stopping."
            log "ERROR: Giving up on the graceful stop - handing over to the OS shutdown to keep it orderly."
            aborted=1
            ABORTED_CRITICAL=1
            break
        fi
        keep_deadline_alive
        [ $((waited % 60)) -eq 0 ] && log "HANA $sid still stopping... (${waited}s elapsed, battery $(battery_capacity)%)"
        sleep "$POLL_INTERVAL"
        waited=$((waited + POLL_INTERVAL))
    done

    if [ "$aborted" -eq 0 ]; then
        wait "$stop_pid"; rc=$?
        sed "s/^/    [$sid] /" "$STOP_OUT"
        if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
            log "Warning: 'HDB stop' for $sid exceeded the hard limit of ${HANA_STOP_TIMEOUT}s."
        elif [ "$rc" -ne 0 ]; then
            log "Warning: 'HDB stop' for $sid returned exit code $rc after ${waited}s."
        else
            log "'HDB stop' for $sid returned successfully after ${waited}s."
        fi
    else
        sed "s/^/    [$sid] /" "$STOP_OUT"
    fi
    rm -f "$STOP_OUT"

    # Verify: no HANA process may be left over
    if [ "$aborted" -eq 0 ] && instance_is_stopped "$adm" "$nr"; then
        log "HANA database $sid is stopped cleanly."
    else
        log "Warning: HANA database $sid is NOT confirmed down. No kill is issued (log_mode=overwrite)."
        HANA_ALL_STOPPED=0
        EXIT_CODE=1
    fi

    run_as "$adm" 60 "HDB info" | sed "s/^/    [$sid] /"
done

# ------------------------------------------------------------------------------
# Step 3: Flush everything to disk, then power off
# ------------------------------------------------------------------------------
log "Syncing file systems..."
[ "$DRY_RUN" -eq 0 ] && sync && sync

if [ "$EXIT_CODE" -eq 0 ]; then
    log "S/4HANA shutdown hook completed successfully. Safe to power off."
else
    log "S/4HANA shutdown hook completed WITH WARNINGS. Check the log above."
fi

if [ "$DRY_RUN" -eq 0 ] && [ "$ABORTED_CRITICAL" -eq 1 ]; then
    # We may have pushed the deadline minutes into the future, but the battery will
    # not last that long. Shut down NOW so systemd can stop the services and unmount
    # the file systems in order, instead of losing power mid-write.
    log "Battery floor reached: shutting down immediately to stay ahead of the power loss."
    shutdown -h now "Battery critically low. Immediate orderly shutdown." >/dev/null 2>&1
elif [ "$POWEROFF_WHEN_DONE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    if [ "$(battery_status)" != "Discharging" ]; then
        log "AC power is back ($(battery_status)). Not powering off - leaving the decision to power_monitor.sh."
    elif [ "$HANA_ALL_STOPPED" -eq 1 ]; then
        log "Database is down and battery is still on ($(battery_capacity)%). Powering off in 1 minute."
        shutdown -h +1 "SAP S/4HANA stopped cleanly. Powering off to preserve battery." >/dev/null 2>&1
    else
        log "Database state unclear - keeping the deadline set by power_monitor.sh instead of powering off now."
    fi
fi

exit "$EXIT_CODE"
