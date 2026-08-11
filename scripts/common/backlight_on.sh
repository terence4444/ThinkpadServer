#!/bin/bash
# ==============================================================================
# Script Name: backlight_on.sh
# Description: Turn on or step up notebook screen brightness (10% step)
#              with safety limits and one-key wake-up.
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

# Write the given brightness value, failing loudly instead of reporting success
write_brightness() {
    if ! echo "$1" > "$BACKLIGHT_DIR/brightness" 2>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Cannot write $1 to $BACKLIGHT_DIR/brightness." >&2
        exit 1
    fi
}

MAX_BRIGHTNESS=$(cat "$BACKLIGHT_DIR/max_brightness" 2>/dev/null)
CURRENT_BRIGHTNESS=$(cat "$BACKLIGHT_DIR/brightness" 2>/dev/null)

if [ -z "$MAX_BRIGHTNESS" ] || [ -z "$CURRENT_BRIGHTNESS" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Cannot read brightness or max_brightness." >&2
    exit 1
fi

# Calculate 10% step size (minimum step of 1)
STEP=$((MAX_BRIGHTNESS / 10))
if [ $STEP -lt 1 ]; then
    STEP=1
fi

# If current brightness is 0 (completely off), wake up to a safe 20% default
if [ "$CURRENT_BRIGHTNESS" -eq 0 ]; then
    NEW_BRIGHTNESS=$((MAX_BRIGHTNESS * 2 / 10))
    write_brightness "$NEW_BRIGHTNESS"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Screen woke up. Brightness set to 20% ($NEW_BRIGHTNESS)."
    exit 0
fi

# Otherwise, step up by 10%
NEW_BRIGHTNESS=$((CURRENT_BRIGHTNESS + STEP))

# If new brightness exceeds max_brightness, loop back to 10%
if [ $NEW_BRIGHTNESS -gt $MAX_BRIGHTNESS ]; then
    NEW_BRIGHTNESS=$((MAX_BRIGHTNESS / 10))
fi

write_brightness "$NEW_BRIGHTNESS"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Brightness stepped up to $NEW_BRIGHTNESS."
