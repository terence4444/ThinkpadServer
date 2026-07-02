# Custom Modular Shutdown Scripts Directory

This directory contains examples of modular shutdown scripts that are executed automatically when the battery capacity falls below the safe threshold (40%) and the system initiates its 10-minute graceful shutdown sequence.

## How it works

1. The main power monitor script (`scripts/common/power_monitor.sh`) is run every 10 minutes via cron.
2. If a power outage is detected (discharging) and the battery level is below 40%, the script:
   - Sets a lock file (`/var/run/power_monitor_shutdown.lock`) to prevent multiple executions.
   - Searches `/etc/power_monitor.d/` for executable custom scripts.
   - Executes each script in the background.
   - Syncs the filesystems.
   - Schedules a system shutdown in 10 minutes (`/sbin/shutdown -h +10`).
3. The custom scripts run in the background, giving them a 10-minute grace window to gracefully stop high-load databases and applications (e.g. ClickHouse, SAP S/4HANA) before the operating system cuts power.

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
