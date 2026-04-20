#!/bin/bash
# Startup wrapper: starts freeciv-server with a FIFO for stdin,
# monitors for connections (auto-take), and turn changes (email notifications).

FIFO=/tmp/server-input
SAVE_DIR=/data/saves
WEBROOT=/opt/freeciv/www
LOGFILE=/data/saves/server.log
MARKER=/tmp/last-notified-turn
# Two epoch files track the turn timer:
#
# TURN_START_FILE: Used by the STATUS PAGE to display the countdown.
#   Set to NOW whenever the timeout is (re)set — including mid-turn restarts.
#   The status page calculates: deadline = turn_start_epoch + live_timeout.
#   On a fresh turn: set to NOW (same as real start).
#   On a mid-turn restart: set to NOW (even though the turn started earlier),
#     because the live_timeout is now a reduced value matching the remaining time.
#
# REAL_TURN_START_FILE: Used by the STARTUP SCRIPT to survive multiple restarts.
#   Set to NOW only when a genuinely new turn begins. Never overwritten on restart.
#   The startup script calculates: remaining = 23h - (NOW - real_turn_start).
#   This prevents timer drift when deploying multiple times in one turn.
#
# On a new turn: both files get the same value (NOW).
# On a mid-turn restart: only TURN_START_FILE changes (to NOW), while
#   REAL_TURN_START_FILE stays at the original turn start time.
TURN_START_FILE=/data/saves/turn_start_epoch
REAL_TURN_START_FILE=/data/saves/real_turn_start_epoch

mkdir -p "$SAVE_DIR/archived"
# Move any existing timestamped saves out of the main directory
for f in "$SAVE_DIR"/lt-game-*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*.sav.gz; do
  [ -f "$f" ] && mv "$f" "$SAVE_DIR/archived/"
done
rm -f "$FIFO" "$LOGFILE"
mkfifo "$FIFO"
touch "$LOGFILE"

# Trap SIGTERM (sent by Fly.io on deploy) — force a save before shutting down
shutdown_save() {
  echo "[shutdown] SIGTERM received — forcing save before exit"
  echo "save" > "$FIFO" 2>/dev/null
  sleep 3
  # Timestamp the shutdown save and update save-latest
  LATEST_SAV=$(ls -1t "$SAVE_DIR"/lt-game-*.sav.gz 2>/dev/null | head -1)
  if [ -n "$LATEST_SAV" ]; then
    TURN_NUM=$(echo "$LATEST_SAV" | sed 's/.*lt-game-\([0-9]*\)[.-].*/\1/')
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    cp "$LATEST_SAV" "$SAVE_DIR/archived/lt-game-${TURN_NUM}-${TIMESTAMP}.sav.gz"
    cp "$LATEST_SAV" "$SAVE_DIR/save-latest.sav.gz"
    echo "[shutdown] Archived: archived/lt-game-${TURN_NUM}-${TIMESTAMP}.sav.gz"
  fi
  echo "[shutdown] Save complete, exiting"
  kill 0
  exit 0
}
trap shutdown_save TERM

# Only initialize marker if it doesn't exist (preserve across restarts)
if [ ! -f "$MARKER" ]; then
  echo "1" > "$MARKER"
fi

# Check for existing save files — if found, resume from save-latest
LATEST_SAVE=""
if [ -f "$SAVE_DIR/save-latest.sav.gz" ]; then
  LATEST_SAVE="$SAVE_DIR/save-latest.sav.gz"
elif ls "$SAVE_DIR"/lt-game-*.sav.* 1>/dev/null 2>&1; then
  LATEST_SAVE=$(ls -1t "$SAVE_DIR"/lt-game-*.sav.* 2>/dev/null | head -1)
fi
if [ -n "$LATEST_SAVE" ]; then
  echo "[startup] Found existing save: $LATEST_SAVE — will resume game"
  # Read phase_seconds and timeout from save to calculate remaining turn time,
  # then reset phase_seconds=0 to prevent freeciv from auto-advancing on resume
  TMPFILE=$(mktemp /tmp/freeciv-fixsave-XXXXXX)
  zcat "$LATEST_SAVE" > "$TMPFILE" 2>/dev/null
  SAVE_PHASE_SECONDS=0
  SAVE_TIMEOUT=82800
  if [ -s "$TMPFILE" ]; then
    SAVE_PHASE_SECONDS=$(grep '^phase_seconds=' "$TMPFILE" | head -1 | sed 's/phase_seconds=//')
    SAVE_TIMEOUT=$(grep '^"timeout",' "$TMPFILE" | head -1 | cut -d',' -f2)
    [ -z "$SAVE_PHASE_SECONDS" ] && SAVE_PHASE_SECONDS=0
    [ -z "$SAVE_TIMEOUT" ] && SAVE_TIMEOUT=82800
    SAVE_TURN_NUM=$(grep '^turn=' "$TMPFILE" | head -1 | sed 's/turn=//')
    [ -z "$SAVE_TURN_NUM" ] && SAVE_TURN_NUM=0
    sed -i 's/^phase_seconds=.*/phase_seconds=0/' "$TMPFILE"
    gzip -c "$TMPFILE" > "$LATEST_SAVE"
    echo "[startup] Save had phase_seconds=$SAVE_PHASE_SECONDS, timeout=$SAVE_TIMEOUT"
    echo "[startup] Reset phase_seconds to 0 to prevent auto-advance"
  fi
  rm -f "$TMPFILE"
  # Calculate remaining turn time
  # Most reliable source: mtime of the PREVIOUS turn's save file.
  # That's when the current turn started and it's immutable on disk.
  # Falls back to real_turn_start_epoch, then phase_seconds.
  DEFAULT_TIMEOUT=82800
  NOW_EPOCH=$(date +%s)
  PREV_TURN_NUM=$((SAVE_TURN_NUM - 1))
  PREV_SAVE="$SAVE_DIR/lt-game-${PREV_TURN_NUM}.sav.gz"
  if [ -f "$PREV_SAVE" ]; then
    # The previous turn's save was written at the moment the current turn started
    TURN_ACTUAL_START=$(stat -c %Y "$PREV_SAVE" 2>/dev/null || stat -f %m "$PREV_SAVE" 2>/dev/null)
    REAL_ELAPSED=$((NOW_EPOCH - TURN_ACTUAL_START))
    RESUME_REMAINING=$((DEFAULT_TIMEOUT - REAL_ELAPSED))
    echo "[startup] Turn $SAVE_TURN_NUM started when lt-game-${PREV_TURN_NUM}.sav.gz was written"
    echo "[startup] Turn started ${REAL_ELAPSED}s ago ($(( REAL_ELAPSED / 3600 ))h $(( (REAL_ELAPSED % 3600) / 60 ))m), remaining=${RESUME_REMAINING}s"
    # Update real_turn_start_epoch to match
    echo "$TURN_ACTUAL_START" > "$REAL_TURN_START_FILE"
  elif [ -f "$REAL_TURN_START_FILE" ]; then
    TURN_START_SAVED=$(cat "$REAL_TURN_START_FILE")
    REAL_ELAPSED=$((NOW_EPOCH - TURN_START_SAVED))
    RESUME_REMAINING=$((DEFAULT_TIMEOUT - REAL_ELAPSED))
    echo "[startup] Using real_turn_start_epoch (fallback): started ${REAL_ELAPSED}s ago, remaining=${RESUME_REMAINING}s"
  else
    RESUME_REMAINING=$((DEFAULT_TIMEOUT - SAVE_PHASE_SECONDS))
    echo "[startup] No previous save or epoch file, using phase_seconds: remaining=${RESUME_REMAINING}s"
  fi
  if [ "$RESUME_REMAINING" -lt 60 ]; then
    RESUME_REMAINING=60
    echo "[startup] Turn has expired or nearly expired — will end in 60s"
  else
    echo "[startup] Remaining turn time: ${RESUME_REMAINING}s ($(( RESUME_REMAINING / 3600 ))h $(( (RESUME_REMAINING % 3600) / 60 ))m)"
  fi
  RESUME_MODE=true
  # Update marker to the save's turn number so we don't re-send notifications
  SAVE_TURN="$SAVE_TURN_NUM"
  if [ -n "$SAVE_TURN" ] && [ "$SAVE_TURN" -gt 0 ] 2>/dev/null; then
    echo "$SAVE_TURN" > "$MARKER"
    echo "[startup] Set notification marker to turn $SAVE_TURN"
  fi
  # Initialize turn start epoch from save mtime if not already set
  if [ ! -f "$TURN_START_FILE" ]; then
    SAVE_EPOCH=$(stat -c %Y "$LATEST_SAVE" 2>/dev/null || echo "$(date +%s)")
    echo "$SAVE_EPOCH" > "$TURN_START_FILE"
    echo "[startup] Initialized turn_start_epoch to $SAVE_EPOCH"
  fi
else
  echo "[startup] No existing saves — starting fresh game"
  RESUME_MODE=false
fi

# Process 1: FIFO writer — sends startup commands and auto-take on connect
(
  exec 3>"$FIFO"

  # Wait for the game to fully start
  while ! grep -q "Now accepting" "$LOGFILE" 2>/dev/null; do
    sleep 1
  done
  sleep 2

  # When resuming from save, the game is in pregame state — need to send 'start' to resume
  # When starting fresh, longturn.serv already contains 'start' at the end
  if [ "$RESUME_MODE" = "true" ]; then
    # Set a huge timeout BEFORE 'start' to prevent freeciv from auto-advancing
    # the turn (it checks if the saved turn's timeout has elapsed on resume)
    echo "[fifo-writer] Setting temporary huge timeout to prevent auto-advance"
    echo "set unitwaittime 1" >&3
    sleep 1
    echo "set timeout 999999" >&3
    sleep 1

    echo "[fifo-writer] Sending 'start' to resume game from save"
    echo "start" >&3
    sleep 3

    # Set the real timeout based on remaining turn time from the save file
    if [ "$RESUME_REMAINING" -gt 0 ] && [ "$RESUME_REMAINING" -lt 82800 ]; then
      UWT=$((RESUME_REMAINING * 2 / 3))
      echo "[fifo-writer] Setting timeout to ${RESUME_REMAINING}s ($(( RESUME_REMAINING / 3600 ))h $(( (RESUME_REMAINING % 3600) / 60 ))m remaining)"
      echo "set unitwaittime $UWT" >&3
      sleep 1
      echo "set timeout $RESUME_REMAINING" >&3
      sleep 1
      # turn_start_epoch = NOW so status page calculates: NOW + reduced_timeout = correct deadline
      date +%s > "$TURN_START_FILE"
      # real_turn_start_epoch preserves the actual turn start for future restart calculations
      if [ ! -f "$REAL_TURN_START_FILE" ]; then
        echo $(($(date +%s) - (DEFAULT_TIMEOUT - RESUME_REMAINING))) > "$REAL_TURN_START_FILE"
      fi
      # Refresh status page with the new deadline
      /opt/freeciv/generate_status_json.sh >> /data/saves/status-generator.log 2>&1 &

      # Watch for the next turn and restore normal 23hr settings
      (
        CURRENT_TURN="$SAVE_TURN_NUM"
        NEXT_TURN=$((CURRENT_TURN + 1))
        BASELINE=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
        echo "[timeout-reset] Watching for turn $NEXT_TURN to restore 23hr timeout (from line $BASELINE)"
        while true; do
          sleep 60
          CURRENT_LINES=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
          if [ "$CURRENT_LINES" -gt "$BASELINE" ]; then
            if tail -n +"$((BASELINE + 1))" "$LOGFILE" 2>/dev/null | grep -q "Game saved as.*lt-game-${NEXT_TURN}"; then
              echo "set unitwaittime 36000" > /tmp/server-input
              sleep 2
              echo "set timeout 82800" > /tmp/server-input
              echo "[timeout-reset] Restored 23hr timeout after turn $NEXT_TURN"
              exit 0
            fi
          fi
        done
      ) &
    else
      echo "[fifo-writer] Using default 23hr timeout"
      echo "set unitwaittime 36000" >&3
      sleep 1
      echo "set timeout 82800" >&3
      sleep 1
      date +%s > "$TURN_START_FILE"
      date +%s > "$REAL_TURN_START_FILE"
      /opt/freeciv/generate_status_json.sh >> /data/saves/status-generator.log 2>&1 &
    fi
  else
    # Switch all players from AI to human control (only on fresh game start)
    # When resuming from save, players are already Human — toggling would make them AI again
    for player in shazow hyfen blakkout jess andrew jamsem24 minikeg tracymakes ihop shogun kimjongboom kroony tankerjon peter DetectiveG UncleS; do
      echo "aitoggle $player" >&3
      sleep 1
    done
  fi

  # Poll log for new connections and auto-take
  LAST_CONN_LINE=0
  while true; do
    CURRENT_LINES=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$CURRENT_LINES" -gt "$LAST_CONN_LINE" ]; then
      # Only check NEW lines for connection events
      new_connections=$(tail -n +"$((LAST_CONN_LINE + 1))" "$LOGFILE" 2>/dev/null | grep "has connected from")
      LAST_CONN_LINE=$CURRENT_LINES

      if [ -n "$new_connections" ]; then
        echo "$new_connections" | while read -r line; do
          name=$(echo "$line" | sed 's/.*[0-9]: \(.*\) has connected from.*/\1/')
          if [ -n "$name" ]; then
            echo "[auto-take] Detected connection: $name"
            sleep 1
            echo "take $name $name" >&3
          fi
        done
      fi
    fi
    sleep 2
  done
) &

# Process 2: Turn notification watcher
(
  # Wait for the game to fully start
  while ! grep -q "Now accepting" "$LOGFILE" 2>/dev/null; do
    sleep 1
  done

  echo "[turn-watcher] Started monitoring for turn changes"

  # Track the line count we've already processed
  LAST_LINE=0

  # Poll for new turn saves
  while true; do
    sleep 5

    # Only look at NEW lines in the log (avoid re-matching old saves)
    CURRENT_LINES=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$CURRENT_LINES" -gt "$LAST_LINE" ]; then
      # Check new lines for save events
      new_save=$(tail -n +"$((LAST_LINE + 1))" "$LOGFILE" 2>/dev/null | grep "Game saved as.*lt-game-" | tail -1)
      LAST_LINE=$CURRENT_LINES

      if [ -n "$new_save" ]; then
        turn=$(echo "$new_save" | sed 's/.*lt-game-\([0-9]*\).*/\1/')
        last_notified=$(cat "$MARKER" 2>/dev/null || echo 1)

        # Timestamp the save file and update save-latest
        SAVE_FILE="$SAVE_DIR/lt-game-${turn}.sav.gz"
        if [ -f "$SAVE_FILE" ]; then
          TIMESTAMP=$(date +%Y%m%d-%H%M%S)
          TIMESTAMPED="$SAVE_DIR/archived/lt-game-${turn}-${TIMESTAMP}.sav.gz"
          cp "$SAVE_FILE" "$TIMESTAMPED"
          cp "$SAVE_FILE" "$SAVE_DIR/save-latest.sav.gz"
          echo "[turn-watcher] Archived save: archived/$TIMESTAMPED"
        fi

        echo "[turn-watcher] Detected save for turn $turn (last notified: $last_notified)"

        if [ -n "$turn" ] && [ "$turn" -gt "$last_notified" ] 2>/dev/null; then
          echo "$turn" > "$MARKER"
          date +%s > "$TURN_START_FILE"
          date +%s > "$REAL_TURN_START_FILE"
          # Estimate year (turn_notify.sh will try to read exact year from save file)
          year=$(((-4000 + (turn - 1) * 50)))
          # Refresh status page first so turn_notify.sh can read fresh JSON
          /opt/freeciv/generate_status_json.sh >> /data/saves/status-generator.log 2>&1
          # Generate gazette before email so the email can include it
          /opt/freeciv/generate_gazette.sh "$turn" "$year" >> /data/saves/gazette.log 2>&1
          # Generate player dashboards (incremental — diffs latest turn)
          /opt/freeciv/generate_dashboard.sh >> /data/saves/dashboard.log 2>&1 &
          # Editor proactive outreach (contacts 1-2 interesting players per turn)
          /opt/freeciv/respond_to_editor.sh --outreach >> /data/saves/editor.log 2>&1 &
          echo "[turn-watcher] Triggering notification for turn $turn"
          /opt/freeciv/turn_notify.sh "$turn" "$year" &

          # Clean up archived saves from previous turns: keep only the last one per turn
          for old_turn in $(ls "$SAVE_DIR/archived/" 2>/dev/null | sed 's/lt-game-\([0-9]*\)-.*/\1/' | sort -n | uniq); do
            [ "$old_turn" -ge "$turn" ] 2>/dev/null && continue
            ls -1t "$SAVE_DIR/archived/lt-game-${old_turn}-"*.sav.gz 2>/dev/null | tail -n +2 | xargs rm -f 2>/dev/null
          done
          echo "[turn-watcher] Cleaned up old archived saves"
        fi
      fi
    fi
  done
) &

# Process 5: Periodic auto-save every 5 minutes (protects mid-turn progress)
(
  while ! grep -q "Now accepting" "$LOGFILE" 2>/dev/null; do
    sleep 1
  done
  sleep 10
  echo "[auto-saver] Started — saving every 5 minutes"
  while true; do
    sleep 300
    echo "save" > /tmp/server-input 2>/dev/null
    # Wait for save to complete, then timestamp it
    sleep 5
    LATEST_SAV=$(ls -1t "$SAVE_DIR"/lt-game-*.sav.gz 2>/dev/null | head -1)
    if [ -n "$LATEST_SAV" ]; then
      TURN_NUM=$(echo "$LATEST_SAV" | sed 's/.*lt-game-\([0-9]*\)[.-].*/\1/')
      TIMESTAMP=$(date +%Y%m%d-%H%M%S)
      cp "$LATEST_SAV" "$SAVE_DIR/archived/lt-game-${TURN_NUM}-${TIMESTAMP}.sav.gz"
      cp "$LATEST_SAV" "$SAVE_DIR/save-latest.sav.gz"
      echo "[auto-saver] Archived: archived/lt-game-${TURN_NUM}-${TIMESTAMP}.sav.gz"
    fi
  done
) &

# Process 6: Editor responder — replies to player messages every hour
(
  while ! grep -q "Now accepting" "$LOGFILE" 2>/dev/null; do
    sleep 1
  done
  sleep 30
  echo "[editor-loop] Started — checking for messages every hour"
  while true; do
    sleep 3600
    /opt/freeciv/respond_to_editor.sh >> /data/saves/editor.log 2>&1
    echo "[editor-loop] Ran at $(date)"
  done
) &

# Process 8: Dashboard refresh — updates current state every 5 minutes
(
  while ! grep -q "Now accepting" "$LOGFILE" 2>/dev/null; do
    sleep 1
  done
  sleep 60
  echo "[dashboard-loop] Started — refreshing every 5 minutes"
  while true; do
    sleep 300
    /opt/freeciv/generate_dashboard.sh >> /data/saves/dashboard.log 2>&1
    echo "[dashboard-loop] Refreshed at $(date)"
  done
) &

# Process 7: Turn reminder (nudge emails 2 hours before deadline)
/opt/freeciv/turn_reminder.sh &

# Generate static nations page (runs once)
/opt/freeciv/generate_nations.sh

# Status page generator runs via busybox crond (started in entrypoint.sh) every 5 minutes.
# It's also triggered by the FIFO writer after the server finishes loading (lines above).
# Do NOT run it here — the server hasn't started yet, so it would produce incomplete data.

# Symlink persisted JSON files into webroot so they're served immediately on restart
for f in status.json history.json attendance.json diplomacy.json gazette.json; do
  [ -f "$SAVE_DIR/$f" ] && ln -sf "$SAVE_DIR/$f" "$WEBROOT/$f"
done

# Symlink persisted gazette illustrations into webroot
for f in "$SAVE_DIR"/gazette-*.png; do
  if [ -f "$f" ]; then
    ln -sf "$f" "$WEBROOT/$(basename $f)"
    echo "[startup] Symlinked $(basename $f) into webroot"
  fi
done

# Process 4: HTTP server for status page
busybox httpd -f -p 8080 -h /opt/freeciv/www &

# Start freeciv-server with FIFO as stdin
if [ "$RESUME_MODE" = "true" ]; then
  echo "[startup] Resuming from save: $LATEST_SAVE"
  stdbuf -oL freeciv-server \
    -p 5556 \
    -f "$LATEST_SAVE" \
    -s "$SAVE_DIR" \
    -a \
    -D /etc/freeciv/fcdb.conf \
    < "$FIFO" \
    2>&1 | stdbuf -oL tee "$LOGFILE"
else
  echo "[startup] Starting fresh game from longturn.serv"
  stdbuf -oL freeciv-server \
    -p 5556 \
    -r /etc/freeciv/longturn.serv \
    -s "$SAVE_DIR" \
    -a \
    -D /etc/freeciv/fcdb.conf \
    < "$FIFO" \
    2>&1 | stdbuf -oL tee "$LOGFILE"
fi
