# Custom Modular Shutdown Scripts Directory

This directory contains examples of modular shutdown scripts that are executed automatically when the battery capacity falls below the safe threshold (40%) and the system initiates its 11-minute graceful shutdown sequence.

## How it works

1. The main power monitor script (`scripts/common/power_monitor.sh`) is run every 5 minutes via cron.
2. If a power outage is detected (discharging) and the battery level is below 40%, the script:
   - Detects a pending shutdown through systemd's own state file
     (`/run/systemd/shutdown/scheduled`) instead of a custom lock file, so a
     stale lock can never desynchronise the state.
   - Searches `/etc/power_monitor.d/` for executable custom scripts.
   - Executes each script in the background, in its own session (`setsid`), and
     records the PIDs in `/run/power_monitor_hooks.pids`.
   - Syncs the filesystems.
   - Schedules a system shutdown in 11 minutes (`shutdown -h +11`) - 11 rather
     than 10 so that the cron run at minute 10 still has a 1-minute window to
     cancel the shutdown if power comes back.
3. The custom scripts run in the background, giving them an 11-minute grace
   window to gracefully stop high-load databases and applications (e.g.
   ClickHouse, SAP S/4HANA) before the operating system cuts power.

## Hooks that need more than the grace window

11 minutes is not always enough - stopping SAP HANA can take much longer, and
killing it halfway is exactly what this whole mechanism is meant to prevent.
A hook may therefore postpone the shutdown itself: `20_s4hana.sh` re-issues
`shutdown -h +10` while the database is still stopping (systemd's
ScheduleShutdown overwrites the pending schedule) and powers the machine off as
soon as the database is confirmed down. Its own floor is the battery level, not
the clock.

Two consequences to keep in mind when writing your own hook:

- Make it re-entrant safe. Cron fires again every 5 minutes; use `flock` so a
  second invocation cannot start a second shutdown of the same service.
- If your hook can outlive 11 minutes, `HOOK_WAIT_TIMEOUT` in
  `power_monitor.sh` must be larger than your slowest hook, otherwise the
  self-healing reboot on power restore will cut it off.

## How to Deploy Your Own Custom Scripts

To deploy these custom shutdown scripts on your ThinkPad server:

1. Create the system-wide custom scripts directory:
   ```bash
   sudo mkdir -p /etc/power_monitor.d
   ```

2. Copy the relevant scripts from this directory to `/etc/power_monitor.d/`:
   ```bash
   sudo cp 10_clickhouse.sh /etc/power_monitor.d/
   sudo cp 20_s4hana.sh /etc/power_monitor.d/
   ```

3. Make them executable:
   ```bash
   sudo chmod +x /etc/power_monitor.d/*
   ```

## Naming Convention

It is recommended to prefix your scripts with numbers (e.g., `10_clickhouse.sh`, `20_s4hana.sh`) to control their execution order if executed sequentially (though the monitor executes them in parallel background tasks to maximize concurrency and ensure they all start immediately).

Note that because the hooks run **in parallel**, the number prefix does *not*
order them. If two services must be stopped in a fixed order, put them in the
same hook script.

## Starting the services again

These hooks only stop services. The counterpart for SAP S/4HANA is
`scripts/common/s4hana_start.sh`, which starts the HANA database first and the
ABAP instances afterwards, and refuses to start anything while the machine is
running on battery. It shares the lock file `/run/s4hana_control.lock` with
`20_s4hana.sh`, so a start can never overlap with an outage shutdown.
