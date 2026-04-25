#!/bin/bash
# Turn reminder — sends a nudge email to players who haven't clicked Turn Done
# Runs 2 hours before the turn deadline
# Called by start.sh's reminder process

SAVE_DIR="/data/saves"
DB_PATH="/data/saves/freeciv.sqlite"
LOGFILE="/data/saves/server.log"
SES_SMTP_USER="${SES_SMTP_USER:-}"
SES_SMTP_PASS="${SES_SMTP_PASS:-}"
SES_SMTP_HOST="${SES_SMTP_HOST:-email-smtp.us-east-1.amazonaws.com}"
FROM_EMAIL="${FROM_EMAIL:-freeciv@andrewmcgrath.info}"
SERVER_HOST="${SERVER_HOST:-freeciv.andrewmcgrath.info}"
CC_EMAIL="${CC_EMAIL:-}"
REMINDER_MARKER="/tmp/reminder-sent-turn"
TEST_TO=""
DRY_RUN=""
for arg in "$@"; do
  case "$arg" in
    --test=*) TEST_TO="${arg#--test=}" ;;
    --dry-run) DRY_RUN=true ;;
  esac
done

echo "[turn-reminder] Started"

# Check if emails are enabled
EMAIL_ENABLED=$(cat /opt/freeciv/email_enabled.settings 2>/dev/null | tr -d '[:space:]')
if [ "$EMAIL_ENABLED" != "true" ]; then
  echo "[turn-reminder] Emails disabled (email_enabled.settings != true), exiting"
  exit 0
fi

if [ -z "$SES_SMTP_USER" ] || [ -z "$SES_SMTP_PASS" ]; then
  echo "[turn-reminder] No SES SMTP credentials, exiting"
  exit 0
fi

while true; do
  [ -z "$TEST_TO" ] && [ -z "$DRY_RUN" ] && sleep 60

  # Get current turn from latest save
  LATEST_SAVE=$(ls -1t "$SAVE_DIR"/lt-game-*.sav.* 2>/dev/null | head -1)
  [ -z "$LATEST_SAVE" ] && { [ -n "$TEST_TO" ] || [ -n "$DRY_RUN" ] && exit 1; continue; }

  CURRENT_TURN=$(echo "$LATEST_SAVE" | sed 's/.*lt-game-\([0-9]*\)[.-].*/\1/')
  [ -z "$CURRENT_TURN" ] && { [ -n "$TEST_TO" ] || [ -n "$DRY_RUN" ] && exit 1; continue; }

  # Skip if we already sent a reminder for this turn (not in test mode)
  if [ -z "$TEST_TO" ] && [ -z "$DRY_RUN" ]; then
    LAST_REMINDED=$(cat "$REMINDER_MARKER" 2>/dev/null || echo 0)
    [ "$LAST_REMINDED" = "$CURRENT_TURN" ] && continue
  fi

  # Calculate deadline: turn start time + timeout
  # Use stored turn start epoch (immune to auto-saver overwriting save file mtime)
  TURN_START_EPOCH=$(cat /data/saves/turn_start_epoch 2>/dev/null || echo 0)
  if [ "$TURN_START_EPOCH" = "0" ]; then
    TURN_START_EPOCH=$(stat -c %Y "$LATEST_SAVE" 2>/dev/null || echo 0)
  fi
  [ "$TURN_START_EPOCH" = "0" ] && { [ -n "$TEST_TO" ] || [ -n "$DRY_RUN" ] && exit 1; continue; }

  # Read timeout from save file (format: "timeout",value,default,"status")
  TIMEOUT=$(zcat "$LATEST_SAVE" 2>/dev/null | grep '^"timeout",' | head -1 | cut -d',' -f2)
  [ -z "$TIMEOUT" ] && TIMEOUT=82800

  DEADLINE=$((TURN_START_EPOCH + TIMEOUT))
  NOW=$(date +%s)
  REMAINING=$((DEADLINE - NOW))

  # Only send if we're within the 2-hour window (or in test mode)
  if [ -n "$TEST_TO" ] || [ -n "$DRY_RUN" ] || { [ "$REMAINING" -gt 60 ] && [ "$REMAINING" -le 7200 ]; }; then
    echo "[turn-reminder] Turn $CURRENT_TURN: ${REMAINING}s remaining — checking who hasn't finished"

    # Force a snapshot to get current phase_done state.
    # Save to a "pending" name, wait for the server log to confirm completion
    # (freeciv writes saves directly to the target with no temp+rename, so
    # readers can see partial gzip data otherwise — see savemain.c:139).
    # Then mv into the canonical name so the file we read is always complete.
    rm -f /tmp/reminder-snapshot-pending.sav* /tmp/reminder-snapshot.sav*
    PRE_SAVE_LINES=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
    echo "save /tmp/reminder-snapshot-pending" > /tmp/server-input 2>/dev/null

    SNAP_WAIT=0
    while [ $SNAP_WAIT -lt 15 ]; do
      sleep 1
      SNAP_WAIT=$((SNAP_WAIT + 1))
      tail -n +"$((PRE_SAVE_LINES + 1))" "$LOGFILE" 2>/dev/null \
        | grep -q "Game saved as /tmp/reminder-snapshot-pending" && break
    done

    PENDING_FILE=$(ls -1t /tmp/reminder-snapshot-pending.sav* 2>/dev/null | head -1)
    if [ -z "$PENDING_FILE" ]; then
      echo "[turn-reminder] Snapshot did not complete within ${SNAP_WAIT}s, will retry"
      continue
    fi
    SNAP_FILE="${PENDING_FILE/-pending/}"
    mv "$PENDING_FILE" "$SNAP_FILE"

    SNAP_TMP=$(mktemp /tmp/freeciv-remind-XXXXXX)
    case "$SNAP_FILE" in
      *.gz)  gzip -dc "$SNAP_FILE" > "$SNAP_TMP" 2>/dev/null ;;
      *.xz)  xz -dc "$SNAP_FILE" > "$SNAP_TMP" 2>/dev/null ;;
      *.bz2) bzip2 -dc "$SNAP_FILE" > "$SNAP_TMP" 2>/dev/null ;;
      *.zst) zstd -dc "$SNAP_FILE" > "$SNAP_TMP" 2>/dev/null ;;
      *)     cp "$SNAP_FILE" "$SNAP_TMP" ;;
    esac
    rm -f /tmp/reminder-snapshot.sav*

    if [ ! -s "$SNAP_TMP" ]; then
      rm -f "$SNAP_TMP"
      continue
    fi

    # Build list of players who haven't finished
    NUM_PLAYERS=$(grep -c '^\[player[0-9]' "$SNAP_TMP" 2>/dev/null || echo 0)
    SLACKERS=""

    for i in $(seq 0 $((NUM_PLAYERS - 1))); do
      SECTION=$(sed -n "/^\[player${i}\]/,/^\[/p" "$SNAP_TMP" | head -150)
      p_name=$(echo "$SECTION" | grep '^name=' | head -1 | sed 's/name="//' | sed 's/"//')
      p_done=$(echo "$SECTION" | grep '^phase_done=' | head -1 | sed 's/phase_done=//')
      p_alive=$(echo "$SECTION" | grep '^is_alive=' | head -1 | sed 's/is_alive=//')

      # Skip barbarians and dead players
      case "$p_name" in *arbarian*|Lion|Pirates) continue ;; esac
      [ "$p_alive" = "FALSE" ] && continue

      if [ "$p_done" != "TRUE" ]; then
        SLACKERS="${SLACKERS}${p_name}\n"
      fi
    done

    rm -f "$SNAP_TMP"

    SLACKER_LIST=$(echo -e "$SLACKERS" | grep -v '^$')
    SLACKER_COUNT=$(echo "$SLACKER_LIST" | grep -c . 2>/dev/null || echo 0)

    if [ "$SLACKER_COUNT" -eq 0 ]; then
      echo "[turn-reminder] Everyone is done! No reminders needed."
      echo "$CURRENT_TURN" > "$REMINDER_MARKER"
      continue
    fi

    echo "[turn-reminder] $SLACKER_COUNT players haven't finished: $(echo "$SLACKER_LIST" | tr '\n' ', ')"

    # Format remaining time for email
    REM_HRS=$((REMAINING / 3600))
    REM_MINS=$(( (REMAINING % 3600) / 60 ))
    if [ "$REM_HRS" -gt 0 ]; then
      TIME_LEFT="${REM_HRS}h ${REM_MINS}m"
    else
      TIME_LEFT="${REM_MINS} minutes"
    fi

    # Build waiting list HTML once (used in all emails)
    WAITING_HTML=""
    while IFS= read -r sn; do
      [ -z "$sn" ] && continue
      WAITING_HTML="${WAITING_HTML}<span style='color:#e94560;'>&#x23F3; ${sn}</span><br>"
    done <<EOF_SLACKERS
$SLACKER_LIST
EOF_SLACKERS

    # Send emails only to slackers — use here-string to avoid subshell
    while IFS= read -r SLACKER_NAME; do
      [ -z "$SLACKER_NAME" ] && continue

      # Look up email from database (or use test address)
      if [ -n "$TEST_TO" ]; then
        SLACKER_EMAIL="$TEST_TO"
      else
        SLACKER_EMAIL=$(sqlite3 "$DB_PATH" "SELECT email FROM fcdb_auth WHERE LOWER(name)=LOWER('$SLACKER_NAME') AND email IS NOT NULL AND email != '';" 2>/dev/null)
        [ -z "$SLACKER_EMAIL" ] && continue
      fi

      echo "[turn-reminder] Nudging $SLACKER_NAME ($SLACKER_EMAIL)"

      EMAIL_MSG=$(cat <<EMAILEOF
From: Freeciv Server <$FROM_EMAIL>
To: $SLACKER_EMAIL
$([ -n "$CC_EMAIL" ] && echo "Cc: $CC_EMAIL")
Subject: Hey ${SLACKER_NAME} — your turn is due in ${TIME_LEFT}!
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8

<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"></head>
<body style="margin:0;padding:0;background:#0f0f1a;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;">
<div style="max-width:600px;margin:0 auto;background:#1a1a2e;color:#e0e0e0;">

  <div style="background:#8b0000;padding:20px 24px;text-align:center;">
    <div style="font-size:32px;margin-bottom:8px;">&#x23F0;</div>
    <div style="font-size:22px;font-weight:800;color:#fff;">Turn Due in ${TIME_LEFT}!</div>
    <div style="font-size:14px;color:#ffcdd2;margin-top:4px;">Turn ${CURRENT_TURN} &middot; Don't hold up the game!</div>
  </div>

  <div style="padding:24px;">
    <p style="font-size:15px;color:#ccc;margin:0 0 16px 0;">
      Hey <strong style="color:#fff;">${SLACKER_NAME}</strong> — the turn deadline is in <strong style="color:#e94560;">${TIME_LEFT}</strong> and you haven't clicked <strong>Turn Done</strong> yet.
    </p>

    <p style="font-size:15px;color:#ccc;margin:0 0 20px 0;">
      Everyone else is waiting on you, sucker! Log in, make your moves, and hit that Turn Done button so we can keep this game rolling. &#x1F3C3;
    </p>

    <div style="background:#1e2a45;border-radius:6px;padding:14px 16px;margin:16px 0;border-left:3px solid #e94560;">
      <div style="color:#e94560;font-weight:bold;font-size:13px;margin-bottom:6px;">&#x23F3; Still waiting on ${SLACKER_COUNT} player(s)</div>
      <div style="color:#999;font-size:13px;">If you don't finish in time, the turn will auto-advance and your units will just sit there doing nothing. Don't be that person.</div>
    </div>

    <div style="text-align:center;margin:28px 0 20px 0;">
      <div style="background:#e94560;color:#fff;display:inline-block;padding:14px 32px;border-radius:6px;font-size:16px;font-weight:bold;letter-spacing:0.3px;">Play Your Turn Now</div>
      <div style="color:#537895;font-size:12px;margin-top:8px;">${SERVER_HOST} &middot; port 5556</div>
    </div>

    <div style="background:#1e2a45;border-radius:6px;padding:14px 16px;margin:12px 0;border-left:3px solid #4caf50;">
      <div style="color:#a5d6a7;font-weight:bold;font-size:13px;margin-bottom:3px;">Remember</div>
      <div style="color:#7a8fa6;font-size:12px;">Click <strong>Turn Done</strong> when you've finished your moves. If all players click it, the next turn starts immediately — no waiting!</div>
    </div>
  </div>

  <div style="padding:16px 24px;text-align:center;border-top:1px solid #2a2a4a;">
    <span style="color:#3a3a5a;font-size:11px;">Freeciv Longturn Server &middot; <a href="https://${SERVER_HOST}" style="color:#3a3a5a;">${SERVER_HOST}</a></span>
  </div>

</div>
</body>
</html>
EMAILEOF
)

      if [ -n "$DRY_RUN" ]; then
        echo "[turn-reminder] DRY RUN — would send to $SLACKER_NAME ($SLACKER_EMAIL)"
      else
        echo "$EMAIL_MSG" | curl -s --url "smtps://$SES_SMTP_HOST:465" \
          --ssl-reqd \
          --mail-from "$FROM_EMAIL" \
          --mail-rcpt "$SLACKER_EMAIL" \
          ${CC_EMAIL:+--mail-rcpt "$CC_EMAIL"} \
          --user "$SES_SMTP_USER:$SES_SMTP_PASS" \
          --upload-file - 2>&1

        if [ $? -eq 0 ]; then
          echo "[turn-reminder] Sent reminder to $SLACKER_EMAIL"
        else
          echo "[turn-reminder] Failed to send to $SLACKER_EMAIL"
        fi
      fi
    done <<EOF_SEND
$SLACKER_LIST
EOF_SEND

    # Mark this turn as reminded so we don't spam (skip in test mode)
    if [ -z "$TEST_TO" ] && [ -z "$DRY_RUN" ]; then
      echo "$CURRENT_TURN" > "$REMINDER_MARKER"
    fi
    echo "[turn-reminder] Done — reminders sent for turn $CURRENT_TURN"
    [ -n "$TEST_TO" ] || [ -n "$DRY_RUN" ] && exit 0
  fi
  [ -n "$TEST_TO" ] || [ -n "$DRY_RUN" ] && { echo "[turn-reminder] No slackers found or timing window missed"; exit 0; }
done
