#!/bin/bash
# ==============================================================================
# Script Name: backlight_on.sh
# Description: Turn on or step up notebook screen brightness (10% step)
#              with safety limits and one-key wake-up.
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
    echo $NEW_BRIGHTNESS > "$BACKLIGHT_DIR/brightness"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Screen woke up. Brightness set to 20% ($NEW_BRIGHTNESS)."
    exit 0
fi

# Otherwise, step up by 10%
NEW_BRIGHTNESS=$((CURRENT_BRIGHTNESS + STEP))

# If new brightness exceeds max_brightness, loop back to 10%
if [ $NEW_BRIGHTNESS -gt $MAX_BRIGHTNESS ]; then
    NEW_BRIGHTNESS=$((MAX_BRIGHTNESS / 10))
fi

echo $NEW_BRIGHTNESS > "$BACKLIGHT_DIR/brightness"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Brightness stepped up to $NEW_BRIGHTNESS."
