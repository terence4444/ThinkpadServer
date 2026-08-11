#!/bin/bash
# ==============================================================================
# Script Name: s4hana_start.sh
# Description: Start a SAP S/4HANA system (SAP HANA database + ABAP application
#              server) on this ThinkPad server, in SAP's documented order and
#              with the safety guards a battery-powered server needs.
#
#              Counterpart of scripts/common/shutdown.d/20_s4hana.sh. Both share
#              the same configuration file and the same lock, so a start can
#              never overlap with a power-outage shutdown.
#
#              Start order (the reverse of the shutdown order):
#                1. Safety guards: AC power, battery level, /hana mounts,
#                   no pending OS shutdown
#                2. Start sapstartsrv (sapinit) - sapcontrol needs it
#                3. Start the HANA database        (HDB start)
#                4. Wait until all HANA processes are GREEN
#                5. Start the ABAP instances       (sapcontrol StartSystem ALL)
#                6. Wait until GREEN, then print the instance list
#
#              Manual equivalent (as reference):
#                su - <hdbsid>adm -c "HDB start"
#                su - <hdbsid>adm -c "HDB info"
#                su - <sid>adm    -c "sapcontrol -nr <nr> -function StartSystem ALL"
#                su - <sid>adm    -c "sapcontrol -nr <nr> -function GetSystemInstanceList"
#
# Usage:       sudo /usr/local/bin/s4hana_start.sh [--force] [--dry-run] [--no-wait]
#                --force    ignore the AC power / battery level guards
#                --dry-run  only show what would be done
#                --no-wait  fire the start commands without waiting for GREEN
#
# Deployment:  sudo cp s4hana_start.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/s4hana_start.sh
#
#              Optional: start automatically after a (self-healing) reboot.
#              SAP's own autostart is deliberately not used here, because it
#              would also start the database when the machine boots on battery
#              during a power outage. Create /etc/systemd/system/s4hana.service:
#
#                [Unit]
#                Description=Start SAP S/4HANA (HANA database, then ABAP)
#                After=network-online.target remote-fs.target sapinit.service
#                Wants=network-online.target remote-fs.target
#                RequiresMountsFor=/hana/data /hana/log /hana/shared /usr/sap
#
#                [Service]
#                Type=oneshot
#                RemainAfterExit=yes
#                TimeoutStartSec=0
#                ExecStart=/usr/local/bin/s4hana_start.sh
#
#                [Install]
#                WantedBy=multi-user.target
#
#              then: sudo systemctl daemon-reload && sudo systemctl enable s4hana.service
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

HANA_START_TIMEOUT=1800     # hard upper bound for "HDB start"
ABAP_START_TIMEOUT=900      # seconds to wait for the application servers to go GREEN
POLL_INTERVAL=10            # status polling interval in seconds

# Do not start a 192 GB in-memory database while the machine is running on
# battery: loading the row/column store would drain the remaining runtime and
# power_monitor.sh would immediately have to stop it again.
REQUIRE_AC_POWER=1
START_MIN_BATTERY=40        # also require at least this battery level

# File systems that must be mounted before HANA may be started: if the vg_hana
# volumes are missing, HANA would happily write into the root file system.
# These are the mount points from docs/sap_s4hana_thinkpad/storage_hana.md - add
# /usr/sap here only if you gave it its own logical volume.
REQUIRED_MOUNTS="/hana/data /hana/log /hana/shared"

LOG_FILE="/var/log/s4hana_start.log"
# Shared with shutdown.d/20_s4hana.sh so that start and stop are mutually exclusive
LOCK_FILE="/run/s4hana_control.lock"
SYSTEMD_SHUTDOWN_FILE="/run/systemd/shutdown/scheduled"
BATTERY_PATH="/sys/class/power_supply/BAT0"
HOSTCTRL_SAPCONTROL="/usr/sap/hostctrl/exe/sapcontrol"

FORCE=0
DRY_RUN=0
WAIT_FOR_GREEN=1

[ -r "$CONF_FILE" ] && . "$CONF_FILE"

# ------------------------------------------------------------------------------
# Command line
# ------------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --force)   FORCE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --no-wait) WAIT_FOR_GREEN=0 ;;
        -h|--help)
            sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "Unknown option: $1 (try --help)" >&2
            exit 2 ;;
    esac
    shift
done

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') - [S4HANA-START] $*"
    echo "$line"
    [ -w "$(dirname "$LOG_FILE")" ] && echo "$line" >> "$LOG_FILE"
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

# sapcontrol GetProcessList returns 3 when all processes are GREEN (running)
# and 4 when all are GRAY (stopped).
instance_is_started() {
    local adm="$1" nr="$2" out rc
    out=$(sapctl "$adm" "$nr" 60 GetProcessList); rc=$?
    [ "$rc" -eq 3 ] && return 0
    return 1
}

adm_user() {
    echo "$(echo "$1" | tr '[:upper:]' '[:lower:]')adm"
}

battery_capacity() {
    cat "$BATTERY_PATH/capacity" 2>/dev/null
}

battery_status() {
    cat "$BATTERY_PATH/status" 2>/dev/null
}

# ------------------------------------------------------------------------------
# Auto-detection of installed instances via /usr/sap/<SID>/<INSTANCE><NR>
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
                HDB[0-9][0-9])
                    SAP_HANA_INSTANCES="$SAP_HANA_INSTANCES $sid:${inst#HDB}" ;;
                DVEBMGS[0-9][0-9]|ASCS[0-9][0-9]|SCS[0-9][0-9]|ERS[0-9][0-9]|D[0-9][0-9]|J[0-9][0-9]|W[0-9][0-9]|G[0-9][0-9]|SMDA[0-9][0-9])
                    SAP_ABAP_INSTANCES="$SAP_ABAP_INSTANCES $sid:${inst##*[A-Z]}" ;;
            esac
        done
    done
    shopt -u nullglob
}

# ------------------------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------------------------
exec 9>"$LOCK_FILE" || exit 1
if ! flock -n 9; then
    log "Error: Another S/4HANA start or shutdown operation is already running. Aborting."
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    log "Error: This script must run as root (it switches to the <sid>adm users)."
    exit 1
fi

# Never start the database into a pending power-off
if [ -f "$SYSTEMD_SHUTDOWN_FILE" ] && [ "$FORCE" -eq 0 ]; then
    log "Error: An OS shutdown is already scheduled (power outage handling?). Refusing to start."
    log "       Cancel it with 'sudo shutdown -c' first, or use --force."
    exit 1
fi

# Power guards
if [ "$REQUIRE_AC_POWER" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
    bat_status=$(battery_status)
    bat_cap=$(battery_capacity)
    if [ "$bat_status" = "Discharging" ]; then
        log "Error: The machine is running on battery (${bat_cap:-?}%). Refusing to start SAP HANA."
        log "       Restore AC power first, or override with --force."
        exit 1
    fi
    if [ -n "$bat_cap" ] && [ "$bat_cap" -lt "$START_MIN_BATTERY" ] 2>/dev/null; then
        log "Error: Battery is only ${bat_cap}% (minimum ${START_MIN_BATTERY}%). Refusing to start."
        log "       A new outage would leave no runtime to stop the database again. Use --force to override."
        exit 1
    fi
fi

# Mount guards.
# The test must be "is $mp itself a mount point", NOT "is $mp on some file
# system": an unmounted /hana/data would resolve to / and pass the weaker test.
is_mount_point() {
    if command -v findmnt >/dev/null 2>&1; then
        findmnt --mountpoint "$1" >/dev/null 2>&1
    elif command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$1"
    else
        awk -v m="$1" '$2 == m { found = 1 } END { exit !found }' /proc/mounts
    fi
}

missing_mounts=""
for mp in $REQUIRED_MOUNTS; do
    is_mount_point "$mp" || missing_mounts="$missing_mounts $mp"
done
if [ -n "$missing_mounts" ]; then
    log "Error: Required file systems are not mounted:$missing_mounts"
    log "       Check /etc/fstab and the vg_hana logical volumes before starting HANA."
    exit 1
fi

if [ -z "$SAP_ABAP_INSTANCES$SAP_HANA_INSTANCES" ]; then
    detect_instances
fi
SAP_ABAP_INSTANCES=$(echo "$SAP_ABAP_INSTANCES" | xargs)
SAP_HANA_INSTANCES=$(echo "$SAP_HANA_INSTANCES" | xargs)

if [ -z "$SAP_ABAP_INSTANCES$SAP_HANA_INSTANCES" ]; then
    log "Error: No SAP instance found under /usr/sap. Nothing to start."
    exit 1
fi

log "Starting SAP S/4HANA. Battery: $(battery_capacity)% ($(battery_status))."
log "Database instances    : ${SAP_HANA_INSTANCES:-none}"
log "Application instances : ${SAP_ABAP_INSTANCES:-none}"
[ "$DRY_RUN" -eq 1 ] && log "DRY-RUN mode: nothing will actually be started."

EXIT_CODE=0

# ------------------------------------------------------------------------------
# Step 1: sapstartsrv must be running before sapcontrol can be used
# ------------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    log "[DRY-RUN] Would ensure sapstartsrv is running (sapinit)."
elif systemctl list-unit-files sapinit.service >/dev/null 2>&1 &&
     systemctl cat sapinit.service >/dev/null 2>&1; then
    log "Ensuring sapstartsrv is running (systemctl start sapinit)..."
    systemctl start sapinit 2>&1 | sed 's/^/    /'
elif [ -x /etc/init.d/sapinit ]; then
    log "Ensuring sapstartsrv is running (/etc/init.d/sapinit start)..."
    /etc/init.d/sapinit start 2>&1 | sed 's/^/    /'
else
    log "Info: No sapinit unit or init script found - relying on sapcontrol StartService."
fi

# ------------------------------------------------------------------------------
# Step 2: Start the HANA database FIRST - the application servers cannot
#         connect without it and would abort their startup.
# ------------------------------------------------------------------------------
HANA_READY=1
for e in $SAP_HANA_INSTANCES; do
    sid="${e%%:*}"; nr="${e##*:}"
    adm=$(adm_user "$sid")

    if ! id "$adm" >/dev/null 2>&1; then
        log "Warning: OS user $adm does not exist. Skipping HANA SID $sid."
        HANA_READY=0
        EXIT_CODE=1
        continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "[DRY-RUN] Would run: su - $adm -c 'HDB start'"
        continue
    fi

    # Idempotent: skip if this instance is already up
    if instance_is_started "$adm" "$nr"; then
        log "HANA database $sid (instance $nr) is already running - skipping."
        continue
    fi

    log "Starting HANA database $sid (instance $nr) as $adm: HDB start..."
    START_OUT=$(mktemp /run/s4hana_start_XXXXXX)
    run_as "$adm" "$HANA_START_TIMEOUT" "HDB start" > "$START_OUT" 2>&1 &
    start_pid=$!

    waited=0
    while kill -0 "$start_pid" 2>/dev/null; do
        [ $((waited % 60)) -eq 0 ] && [ "$waited" -gt 0 ] &&
            log "HANA $sid still starting... (${waited}s elapsed)"
        sleep "$POLL_INTERVAL"
        waited=$((waited + POLL_INTERVAL))
    done
    wait "$start_pid"; rc=$?
    sed "s/^/    [$sid] /" "$START_OUT"
    rm -f "$START_OUT"

    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        log "Warning: 'HDB start' for $sid exceeded the hard limit of ${HANA_START_TIMEOUT}s."
    elif [ "$rc" -ne 0 ]; then
        log "Warning: 'HDB start' for $sid returned exit code $rc after ${waited}s."
    fi

    # Confirm every HANA process is GREEN before touching the application servers
    if [ "$WAIT_FOR_GREEN" -eq 1 ]; then
        log "Waiting for HANA $sid to report all processes GREEN..."
        sapctl "$adm" "$nr" $((HANA_START_TIMEOUT + 60)) \
            WaitforStarted "$HANA_START_TIMEOUT" "$POLL_INTERVAL" | sed "s/^/    [$sid] /"
    fi

    if instance_is_started "$adm" "$nr"; then
        log "HANA database $sid is up (all processes GREEN) after ${waited}s."
    else
        log "ERROR: HANA database $sid did not come up completely."
        HANA_READY=0
        EXIT_CODE=1
    fi

    run_as "$adm" 60 "HDB info" | sed "s/^/    [$sid] /"
done

# ------------------------------------------------------------------------------
# Step 3: Start the ABAP/Java application servers
#         StartSystem starts the whole SAP system of that SID in the correct
#         order (ASCS/message+enqueue server first, then the dialog instances).
# ------------------------------------------------------------------------------
if [ -n "$SAP_ABAP_INSTANCES" ] && [ "$HANA_READY" -eq 0 ]; then
    log "ERROR: Skipping the application servers because the database is not ready."
    log "       Fix the database first, then re-run this script."
    EXIT_CODE=1
elif [ -n "$SAP_ABAP_INSTANCES" ]; then
    for sid in $(for e in $SAP_ABAP_INSTANCES; do echo "${e%%:*}"; done | sort -u); do
        adm=$(adm_user "$sid")
        nr=$(for e in $SAP_ABAP_INSTANCES; do [ "${e%%:*}" = "$sid" ] && echo "${e##*:}"; done | sort | head -1)

        if ! id "$adm" >/dev/null 2>&1; then
            log "Warning: OS user $adm does not exist. Skipping SID $sid."
            continue
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            log "[DRY-RUN] Would run: su - $adm -c 'sapcontrol -nr $nr -function StartSystem ALL'"
            continue
        fi

        log "Starting SAP system $sid via instance $nr (sapcontrol StartSystem ALL)..."
        sapctl "$adm" "$nr" 300 StartSystem ALL | sed "s/^/    [$sid] /"
    done

    if [ "$DRY_RUN" -eq 0 ] && [ "$WAIT_FOR_GREEN" -eq 1 ]; then
        log "Waiting up to ${ABAP_START_TIMEOUT}s for the application servers to come up..."
        elapsed=0
        pending="init"
        while [ "$elapsed" -lt "$ABAP_START_TIMEOUT" ]; do
            pending=""
            for e in $SAP_ABAP_INSTANCES; do
                sid="${e%%:*}"; nr="${e##*:}"
                adm=$(adm_user "$sid")
                id "$adm" >/dev/null 2>&1 || continue
                instance_is_started "$adm" "$nr" || pending="$pending $sid/$nr"
            done
            [ -z "$pending" ] && break
            log "Not GREEN yet:$pending (${elapsed}s/${ABAP_START_TIMEOUT}s)"
            sleep "$POLL_INTERVAL"
            elapsed=$((elapsed + POLL_INTERVAL))
        done

        if [ -n "$pending" ]; then
            log "Warning: Application instances are not GREEN after ${ABAP_START_TIMEOUT}s:$pending"
            log "         Check the work directory: /usr/sap/<SID>/<INSTANCE>/work/dev_* and std*"
            EXIT_CODE=1
        else
            log "All SAP application instances are GREEN."
        fi
    fi

    # Final overview
    if [ "$DRY_RUN" -eq 0 ]; then
        for sid in $(for e in $SAP_ABAP_INSTANCES; do echo "${e%%:*}"; done | sort -u); do
            adm=$(adm_user "$sid")
            nr=$(for e in $SAP_ABAP_INSTANCES; do [ "${e%%:*}" = "$sid" ] && echo "${e##*:}"; done | sort | head -1)
            id "$adm" >/dev/null 2>&1 || continue
            log "Instance list of $sid:"
            sapctl "$adm" "$nr" 60 GetSystemInstanceList | sed "s/^/    [$sid] /"
        done
    fi
fi

if [ "$EXIT_CODE" -eq 0 ]; then
    log "SAP S/4HANA startup completed successfully."
else
    log "SAP S/4HANA startup completed WITH ERRORS. Check the log above."
fi

exit "$EXIT_CODE"
