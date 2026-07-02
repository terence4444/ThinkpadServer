#!/bin/bash
# ==============================================================================
# Script Name: backlight_off.sh
# Description: Turn off notebook backlight (0W power, physical black screen)
#              Auto-detects active backlight device (Intel, AMD or ACPI).
# ==============================================================================

# Find the active backlight directory
BACKLIGHT_DIR=""
for dir in /sys/class/backlight/*; do
    if [ -d "$dir" ]; then
        BACKLIGHT_DIR="$dir"
        break
    fi
done

if [ -z "$BACKLIGHT_DIR" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: No backlight device found in /sys/class/backlight/" >&2
    exit 1
fi

# Write 0 to brightness to completely turn off LCD backlight
echo 0 > "$BACKLIGHT_DIR/brightness"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Screen backlight turned off successfully."
