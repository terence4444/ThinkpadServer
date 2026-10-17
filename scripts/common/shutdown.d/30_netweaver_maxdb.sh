#!/bin/bash
# ==============================================================================
# Script Name: 30_netweaver_maxdb.sh
# Description: Modular shutdown hook for a SAP NetWeaver ABAP system on SAP MaxDB
#              (e.g. ERP 6.0 EHP8 "EQ1" on P16EQ1). Triggered by
#              scripts/common/power_monitor.sh when the machine runs on battery
#              below the safe threshold.
#
#              The MaxDB instance runs with "Log Automatic Overwrite = ON" (no log
#              backups), so this hook never kills the database: it postpones the
#              operating system shutdown while "db_offline" is still running and
#              only gives up when the battery reaches the critical floor.
#
#              Shutdown order:
#                1. Stop the ABAP system                  (sapcontrol StopSystem ALL)
#                2. Wait until every instance is GRAY      (GetProcessList)
#                3. Stop the MaxDB database and WAIT       (dbmcli db_offline)
#                4. Verify, sync, then power off
#
#              Manual equivalent (as reference):
#                su - <sid>adm -c "sapcontrol -nr <nr> -function StopSystem ALL"
#                su - <sid>adm -c "sapcontrol -nr <nr> -function GetProcessList"
#                su - <sid>adm -c "dbmcli -U c -d <DBSID> db_offline"
#                su - <sid>adm -c "dbmcli -U c -d <DBSID> db_state"
#
#              Requires the XUSER key "c" (DBM operator CONTROL) for <sid>adm,
#              which SWPM creates for NetWeaver on MaxDB.
#
# Deployment:  sudo cp 30_netweaver_maxdb.sh /etc/power_monitor.d/ && sudo chmod +x /etc/power_monitor.d/30_netweaver_maxdb.sh
# Test run:    sudo DRY_RUN=1 /etc/power_monitor.d/30_netweaver_maxdb.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# Configuration (override in /etc/sysconfig/power_monitor_netweaver_maxdb if needed)
# ------------------------------------------------------------------------------
CONF_FILE="/etc/sysconfig/power_monitor_netweaver_maxdb"

# ABAP instances in "SID:NR" form, space separated. Leave empty for auto-detection
# from the /usr/sap/<SID>/<INSTANCE><NR> directory layout.
#   Example: SAP_ABAP_INSTANCES="EQ1:00 EQ1:01"
SAP_ABAP_INSTANCES=""

ABAP_STOP_TIMEOUT=300       # seconds to wait for the application servers to go GRAY
MAXDB_STOP_TIMEOUT=1800     # hard upper bound for "db_offline" (battery floor hits first)
POLL_INTERVAL=10            # status polling interval in seconds
DBM_USERKEY="c"             # XUSER key of the DBM operator for <sid>adm

# Application servers may be terminated hard on timeout: open transactions are
# simply rolled back by the database, which is a normal DB operation.
FORCE_STOP_ABAP_ON_TIMEOUT=1

# --- Deadline management (see power_monitor.sh: "shutdown -h +11") -------------
KEEP_ALIVE_UNTIL_STOPPED=1  # 1 = postpone the OS shutdown while MaxDB is stopping
EXTEND_MINUTES=10           # each extension pushes the shutdown this far out
EXTEND_THRESHOLD=180        # extend once less than this many seconds remain

# Below this battery level the machine is about to lose power anyway: stop waiting
# and let the OS shut down in an orderly fashion.
CRITICAL_BATTERY=8

# Power off as soon as the database is confirmed down. Skipped automatically if AC
# power came back, so that power_monitor.sh's self-healing reboot can take over.
POWEROFF_WHEN_DONE=1

DRY_RUN="${DRY_RUN:-0}"     # 1 = log the intended actions only, change nothing

LOCK_FILE="/run/netweaver_maxdb_control.lock"
SYSTEMD_SHUTDOWN_FILE="/run/systemd/shutdown/scheduled"
HOSTCTRL_SAPCONTROL="/usr/sap/hostctrl/exe/sapcontrol"
BATTERY_PATH=""

[ -r "$CONF_FILE" ] && . "$CONF_FILE"

# Locate the battery: not every ThinkPad exposes it as BAT0
if [ -z "$BATTERY_PATH" ]; then
    for candidate in /sys/class/power_supply/BAT*; do
        [ -r "$candidate/capacity" ] && { BATTERY_PATH="$candidate"; break; }
    done
fi

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [NW-MAXDB] $*"
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
# GetProcessList returns 4 when all processes are GRAY; an unreachable
# sapstartsrv (no GREEN/YELLOW in the output) also means the instance is down.
instance_is_stopped() {
    local adm="$1" nr="$2" out rc
    out=$(sapctl "$adm" "$nr" 60 GetProcessList); rc=$?
    [ "$rc" -eq 4 ] && return 0
    printf '%s' "$out" | grep -qE 'GREEN|YELLOW' && return 1
    return 0
}

# Derive the SAP OS user from a SID: EQ1 -> eq1adm
adm_user() {
    echo "$(echo "$1" | tr '[:upper:]' '[:lower:]')adm"
}

# MaxDB name of a SAP system: rsdb/dbid in DEFAULT.PFL (falls back to the SID)
dbsid_of() {
    local sid="$1" dbid
    dbid=$(sed -n 's#^[[:space:]]*rsdb/dbid[[:space:]]*=[[:space:]]*\([A-Za-z0-9]*\).*#\1#p' \
        "/sapmnt/$sid/profile/DEFAULT.PFL" 2>/dev/null | tail -1)
    echo "${dbid:-$sid}"
}

# dbmcli wrapper: output of "dbmcli -U <key> -d <DBSID> <command>"
dbm() {
    local adm="$1" dbsid="$2" timeout_s="$3"; shift 3
    run_as "$adm" "$timeout_s" "dbmcli -U $DBM_USERKEY -d $dbsid $*"
}

# Operational state of the database: ONLINE, ADMIN, OFFLINE, ... (empty if unknown)
db_state() {
    dbm "$1" "$2" 60 db_state | awk 'NR > 1 && /^[A-Z]+$/ {print; exit}'
}

battery_capacity() {
    [ -n "$BATTERY_PATH" ] && cat "$BATTERY_PATH/capacity" 2>/dev/null
}

battery_status() {
    [ -n "$BATTERY_PATH" ] && cat "$BATTERY_PATH/status" 2>/dev/null
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
        "SAP MaxDB is still shutting down (no forced kill). Power off postponed." \
        >/dev/null 2>&1; then
        log "OS shutdown deadline had ${remaining}s left - extended to +${EXTEND_MINUTES} min."
    else
        log "Warning: Could not extend the OS shutdown deadline (${remaining}s left)."
    fi
}

# ------------------------------------------------------------------------------
# Auto-detection of installed ABAP instances via /usr/sap/<SID>/<INSTANCE><NR>
# ------------------------------------------------------------------------------
detect_instances() {
    local sid_dir sid inst_dir inst
    shopt -s nullglob
    for sid_dir in /usr/sap/*/; do
        sid=$(basename "$sid_dir")
        case "$sid" in
            hostctrl|trans|tmp|put|ccms|SYS) continue ;;
        esac
        [ ${#sid} -eq 3 ] || continue

        for inst_dir in "$sid_dir"*/; do
            inst=$(basename "$inst_dir")
            [ -d "$inst_dir/exe" ] || [ -d "$inst_dir/work" ] || continue
            case "$inst" in
                DVEBMGS[0-9][0-9]|ASCS[0-9][0-9]|SCS[0-9][0-9]|ERS[0-9][0-9]|D[0-9][0-9]|J[0-9][0-9]|W[0-9][0-9]|G[0-9][0-9])
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
    log "Info: Another NetWeaver/MaxDB shutdown hook is already running. Exiting."
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    log "Error: This hook must run as root (it switches to the <sid>adm users)."
    exit 1
fi

[ -z "$SAP_ABAP_INSTANCES" ] && detect_instances
SAP_ABAP_INSTANCES=$(echo "$SAP_ABAP_INSTANCES" | xargs)

if [ -z "$SAP_ABAP_INSTANCES" ]; then
    log "Info: No SAP instance found under /usr/sap. Nothing to stop."
    exit 0
fi

SIDS=$(for e in $SAP_ABAP_INSTANCES; do echo "${e%%:*}"; done | sort -u | xargs)

log "Power event received. Starting graceful NetWeaver/MaxDB shutdown."
log "ABAP instances : $SAP_ABAP_INSTANCES"
for sid in $SIDS; do log "Database of $sid: MaxDB $(dbsid_of "$sid")"; done
log "Battery: $(battery_capacity)% ($(battery_status)), critical floor ${CRITICAL_BATTERY}%."
[ "$DRY_RUN" -eq 1 ] && log "DRY-RUN mode: no service will actually be stopped."

EXIT_CODE=0
DB_ALL_STOPPED=1
ABORTED_CRITICAL=0

# ------------------------------------------------------------------------------
# Step 1: Stop the ABAP system (StopSystem stops all instances of the SID in the
#         correct order: dialog instances first, then ASCS)
# ------------------------------------------------------------------------------
pending=""
for sid in $SIDS; do
    adm=$(adm_user "$sid")
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
        done
        sleep 10
    fi
    EXIT_CODE=1
elif [ "$DRY_RUN" -eq 0 ]; then
    log "All SAP application instances are stopped."
fi

# ------------------------------------------------------------------------------
# Step 2: Stop the MaxDB database and WAIT for it. db_offline writes a savepoint
#         and stops the kernel. It runs in the background only so that this
#         script stays awake to push the OS deadline and watch the battery floor.
#         There is deliberately NO kill path for the database.
# ------------------------------------------------------------------------------
for sid in $SIDS; do
    adm=$(adm_user "$sid")
    dbsid=$(dbsid_of "$sid")
    id "$adm" >/dev/null 2>&1 || { DB_ALL_STOPPED=0; EXIT_CODE=1; continue; }

    if [ "$DRY_RUN" -eq 1 ]; then
        log "[DRY-RUN] MaxDB $dbsid is currently: $(db_state "$adm" "$dbsid")"
        log "[DRY-RUN] Would run: su - $adm -c 'dbmcli -U $DBM_USERKEY -d $dbsid db_offline' and wait for completion."
        continue
    fi

    log "Stopping MaxDB $dbsid as $adm: dbmcli db_offline..."
    STOP_OUT=$(mktemp /run/power_monitor_nwmaxdb_XXXXXX)
    dbm "$adm" "$dbsid" "$MAXDB_STOP_TIMEOUT" db_offline > "$STOP_OUT" 2>&1 &
    stop_pid=$!

    waited=0
    aborted=0
    while kill -0 "$stop_pid" 2>/dev/null; do
        if battery_is_critical; then
            log "ERROR: Battery dropped to $(battery_capacity)% (floor ${CRITICAL_BATTERY}%) while MaxDB $dbsid was still stopping."
            log "ERROR: Giving up on the graceful stop - handing over to the OS shutdown to keep it orderly."
            aborted=1
            ABORTED_CRITICAL=1
            break
        fi
        keep_deadline_alive
        [ $((waited % 60)) -eq 0 ] && log "MaxDB $dbsid still stopping... (${waited}s elapsed, battery $(battery_capacity)%)"
        sleep "$POLL_INTERVAL"
        waited=$((waited + POLL_INTERVAL))
    done

    if [ "$aborted" -eq 0 ]; then
        wait "$stop_pid"
    fi
    sed "s/^/    [$dbsid] /" "$STOP_OUT"
    rm -f "$STOP_OUT"

    state=$(db_state "$adm" "$dbsid")
    if [ "$aborted" -eq 0 ] && [ "$state" = "OFFLINE" ]; then
        log "MaxDB $dbsid is stopped cleanly (state OFFLINE, ${waited}s)."
    else
        log "Warning: MaxDB $dbsid is NOT confirmed down (state '${state:-unknown}'). No kill is issued."
        DB_ALL_STOPPED=0
        EXIT_CODE=1
    fi
done

# ------------------------------------------------------------------------------
# Step 3: Flush everything to disk, then power off
# ------------------------------------------------------------------------------
log "Syncing file systems..."
[ "$DRY_RUN" -eq 0 ] && sync && sync

if [ "$EXIT_CODE" -eq 0 ]; then
    log "NetWeaver/MaxDB shutdown hook completed successfully. Safe to power off."
else
    log "NetWeaver/MaxDB shutdown hook completed WITH WARNINGS. Check the log above."
fi

if [ "$DRY_RUN" -eq 0 ] && [ "$ABORTED_CRITICAL" -eq 1 ]; then
    log "Battery floor reached: shutting down immediately to stay ahead of the power loss."
    shutdown -h now "Battery critically low. Immediate orderly shutdown." >/dev/null 2>&1
elif [ "$POWEROFF_WHEN_DONE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    if [ "$(battery_status)" != "Discharging" ]; then
        log "AC power is back ($(battery_status)). Not powering off - leaving the decision to power_monitor.sh."
    elif [ "$DB_ALL_STOPPED" -eq 1 ]; then
        log "Database is down and battery is still on ($(battery_capacity)%). Powering off in 1 minute."
        shutdown -h +1 "SAP NetWeaver/MaxDB stopped cleanly. Powering off to preserve battery." >/dev/null 2>&1
    else
        log "Database state unclear - keeping the deadline set by power_monitor.sh instead of powering off now."
    fi
fi

exit "$EXIT_CODE"
