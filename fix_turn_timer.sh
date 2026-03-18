#!/bin/bash
# Fix the turn timer after a server reboot (or any time)
#
# Usage:
#   ./fix_turn_timer.sh <end_hour> [end_minute]
#   ./fix_turn_timer.sh 4          # end turn at 4:00 AM tomorrow
#   ./fix_turn_timer.sh 16 30      # end turn at 4:30 PM today/tomorrow
#
# Sets the current turn's timeout to end at the specified time,
# then spawns a background watcher that restores the normal 23-hour
# timeout once the next turn begins.

APP_NAME="freeciv-longturn"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <end_hour> [end_minute]"
  echo "  Hour is in 24h format (0-23)"
  echo "Example: $0 4      # end at 4:00 AM"
  echo "Example: $0 16 30  # end at 4:30 PM"
  exit 1
fi

END_HOUR="$1"
END_MINUTE="${2:-0}"

# Calculate target time
NOW=$(date +%s)
TARGET=$(date -j -f "%H:%M:%S" "${END_HOUR}:${END_MINUTE}:00" +%s 2>/dev/null)

# If target is in the past, it means tomorrow
if [ "$TARGET" -le "$NOW" ]; then
  TARGET=$((TARGET + 86400))
fi

REMAINING=$((TARGET - NOW))

if [ "$REMAINING" -lt 60 ]; then
  echo "Error: Target time is less than 1 minute away"
  exit 1
fi

HOURS=$((REMAINING / 3600))
MINUTES=$(( (REMAINING % 3600) / 60 ))
UWT=$((REMAINING * 2 / 3))

echo "Current time:  $(date)"
echo "Target end:    $(date -r $TARGET)"
echo "Remaining:     ${HOURS}h ${MINUTES}m (${REMAINING}s)"
echo ""
echo "Setting timeout to ${REMAINING}s with unitwaittime ${UWT}s..."

# Step 1: Set the reduced timeout for this turn
fly ssh console --app "$APP_NAME" -C "sh -c 'echo \"set unitwaittime $UWT\" > /tmp/server-input'"
sleep 2
fly ssh console --app "$APP_NAME" -C "sh -c 'echo \"set timeout $REMAINING\" > /tmp/server-input'"
sleep 2

# Update turn_start_epoch to now so the status page shows the correct deadline
fly ssh console --app "$APP_NAME" -C "sh -c 'date +%s > /data/saves/turn_start_epoch'"

# Step 2: Get current log line count (used as baseline for watcher)
LOGLINES=$(fly ssh console --app "$APP_NAME" -C "wc -l /data/saves/server.log" 2>/dev/null | grep -o '[0-9]*' | head -1)
echo "Server log baseline: line $LOGLINES"

# Get current turn number so the watcher only fires on the NEXT turn (not auto-saves)
CURRENT_TURN=$(fly ssh console --app "$APP_NAME" -C "sh -c 'zcat /data/saves/save-latest.sav.gz 2>/dev/null | grep ^turn= | head -1 | cut -d= -f2'" 2>/dev/null | tr -d '[:space:]')
NEXT_TURN=$((CURRENT_TURN + 1))
echo "Current turn: $CURRENT_TURN, will restore 23hr on turn $NEXT_TURN"

# Step 3: Spawn a background watcher that restores 23hr timeout on next turn
# Uses base64 to avoid quoting issues through fly ssh
WATCHER="#!/bin/sh
LOGFILE=/data/saves/server.log
BASELINE=${LOGLINES}
echo \"[fix-timer-watcher] Watching from line \$BASELINE for next turn to restore 23hr timeout...\"
while true; do
  sleep 30
  CURRENT=\$(wc -l < \"\$LOGFILE\")
  if [ \"\$CURRENT\" -gt \"\$BASELINE\" ]; then
    if tail -n +\"\$((\$BASELINE + 1))\" \"\$LOGFILE\" | grep -q \"Game saved as.*/data/saves/lt-game-${NEXT_TURN}\"; then
      sleep 5
      echo \"set unitwaittime 36000\" > /tmp/server-input
      sleep 2
      echo \"set timeout 82800\" > /tmp/server-input
      echo \"[fix-timer-watcher] Restored 23hr timeout\"
      exit 0
    fi
  fi
done"

B64=$(echo "$WATCHER" | base64)

echo "Spawning background watcher to restore 23hr timeout on next turn..."
fly ssh console --app "$APP_NAME" -C "sh -c 'echo $B64 | base64 -d > /tmp/restore_timeout.sh && chmod +x /tmp/restore_timeout.sh && nohup sh /tmp/restore_timeout.sh > /data/saves/fix-timer-watcher.log 2>&1 &'"

echo ""
echo "Done! Current turn will end at $(date -r $TARGET)"
echo "Normal 23hr turns will resume automatically after that."
