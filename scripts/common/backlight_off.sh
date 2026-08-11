#!/bin/bash
# ==============================================================================
# Script Name: backlight_off.sh
# Description: Turn off notebook backlight (0W power, physical black screen)
#              Auto-detects active backlight device (Intel, AMD or ACPI).
# ==============================================================================

# Find the active backlight directory.
# A native driver (intel_backlight / amdgpu_bl0) is preferred over the firmware
# device acpi_video0: when both exist, acpi_video0 often has no effect at all,
# and it sorts first alphabetically - so picking "the first one" is wrong.
BACKLIGHT_DIR=""
for dir in /sys/class/backlight/*; do
    [ -w "$dir/brightness" ] || continue
    case "$(basename "$dir")" in
        acpi_video*) [ -z "$BACKLIGHT_DIR" ] && BACKLIGHT_DIR="$dir" ;;
        *)           BACKLIGHT_DIR="$dir"; break ;;
    esac
done

if [ -z "$BACKLIGHT_DIR" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: No writable backlight device found in /sys/class/backlight/ (run as root?)" >&2
    exit 1
fi

# Write 0 to brightness to completely turn off LCD backlight
if ! echo 0 > "$BACKLIGHT_DIR/brightness" 2>/dev/null; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Cannot write to $BACKLIGHT_DIR/brightness." >&2
    exit 1
fi
echo "$(date '+%Y-%m-%d %H:%M:%S') - Screen backlight turned off successfully ($BACKLIGHT_DIR)."
