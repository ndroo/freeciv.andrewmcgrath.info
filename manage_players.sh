#!/bin/bash
# Freeciv Player Management Script
# Creates players in the SQLite auth database and sends welcome emails
#
# Usage:
#   ./manage_players.sh add <username> <password> <email> [nation]  (mid-game: DB + in-game + aitoggle + email)
#   ./manage_players.sh create <username> <password> <email>         (DB + email only, for pre-game setup)
#   ./manage_players.sh create-all    (creates all players defined in PLAYERS array below)
#   ./manage_players.sh list          (lists all players)
#   ./manage_players.sh reset         (deletes all players and recreates from PLAYERS array)

# ============================================================
# PLAYER LIST
# Load from players.conf (gitignored) or define inline below.
# Format: "username:password:email:nation"
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/players.conf" ]; then
  source "$SCRIPT_DIR/players.conf"
else
  PLAYERS=(
    # "player1:secretpass:player1@example.com:Canadian"
    # "player2:secretpass:player2@example.com:Roman"
  )
fi

# ============================================================
# Configuration
# ============================================================
APP_NAME="freeciv-longturn"
DB_PATH="/data/saves/freeciv.sqlite"
SES_SMTP_USER="${SES_SMTP_USER:-}"
SES_SMTP_PASS="${SES_SMTP_PASS:-}"
SES_SMTP_HOST="${SES_SMTP_HOST:-email-smtp.us-east-1.amazonaws.com}"
FROM_EMAIL="freeciv@andrewmcgrath.info"
CC_EMAIL="andrewjohnmcgrath@gmail.com"
SERVER_HOST="freeciv.andrewmcgrath.info"

# ============================================================
# Functions
# ============================================================

create_player_remote() {
  local USERNAME="$1"
  local PASSWORD="$2"
  local EMAIL="$3"
  local MD5_PASS
  MD5_PASS=$(echo -n "$PASSWORD" | md5 -q 2>/dev/null || echo -n "$PASSWORD" | md5sum | awk '{print $1}')
  local NOW
  NOW=$(date +%s)

  echo "Creating player: $USERNAME ($EMAIL)"

  fly ssh console --app "$APP_NAME" -C "sqlite3 $DB_PATH \"INSERT OR REPLACE INTO fcdb_auth (name, password, email, createtime, accesstime, address, createaddress, logincount) VALUES ('$USERNAME', '$MD5_PASS', '$EMAIL', $NOW, $NOW, '', '', 0);\"" 2>&1

  if [ $? -eq 0 ]; then
    echo "  -> Player $USERNAME created successfully"
  else
    echo "  -> ERROR creating player $USERNAME"
    return 1
  fi
}

send_welcome_email() {
  local USERNAME="$1"
  local PASSWORD="$2"
  local EMAIL="$3"

  echo "  -> Sending welcome email to $EMAIL"

  EMAIL_BODY=$(cat <<EMAILEOF
From: Freeciv Server <$FROM_EMAIL>
To: $EMAIL
Cc: $CC_EMAIL
Subject: You have been invited to a Freeciv game!
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8

<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
  <h1 style="color: #2c5530;">You have been invited to play Freeciv!</h1>

  <p>Hey <strong>${USERNAME}</strong>, you have been invited to a <strong>Longturn Freeciv</strong> game!</p>

  <div style="background: #f4f4f4; border-radius: 8px; padding: 20px; margin: 20px 0;">
    <h3 style="margin-top: 0;">Your Login Details</h3>
    <table style="width: 100%;">
      <tr><td style="padding: 4px 0;"><strong>Server:</strong></td><td>${SERVER_HOST}</td></tr>
      <tr><td style="padding: 4px 0;"><strong>Port:</strong></td><td>5556</td></tr>
      <tr><td style="padding: 4px 0;"><strong>Username:</strong></td><td>${USERNAME}</td></tr>
      <tr><td style="padding: 4px 0;"><strong>Password:</strong></td><td>${PASSWORD}</td></tr>
    </table>
  </div>

  <div style="background: #1a1a2e; border-radius: 10px; padding: 20px; margin: 20px 0; color: #eee;">
    <h3 style="margin-top: 0; color: #e94560;">🏰 How This Game Works</h3>
    <p style="margin-bottom: 12px;">This is a <strong>Longturn</strong> game — like a board game played by mail. Instead of sitting down for hours, you log in once a day, take your turn, and log out. The game runs 24/7 on a server and progresses one turn at a time.</p>
    <ul style="padding-left: 20px; line-height: 1.8;">
      <li><strong>Each turn has a 23-hour deadline.</strong> Log in anytime within that window to make your moves.</li>
      <li><strong>Click "Turn Done" when you are finished.</strong> If <em>all</em> players click it, the next turn starts right away — no waiting!</li>
      <li><strong>If someone does not finish in time</strong>, the turn advances automatically after 23 hours. Their units simply hold position.</li>
      <li><strong>You will get an email</strong> each time a new turn starts, with rankings and game stats.</li>
      <li><strong>Think of it like chess by mail</strong> — one move a day, but with armies, cities, and diplomacy.</li>
    </ul>
    <p style="margin-bottom: 0; font-size: 13px; color: #a8a8b8;">Typical game pace: ~1 turn per day. A full game can last weeks or months. No rush!</p>
  </div>

  <div style="background: #e8f5e9; border-radius: 8px; padding: 15px; margin: 15px 0;">
    <strong>IMPORTANT:</strong> You must install <strong>Freeciv version 3.2.3</strong>. Other versions will not connect to this server.
  </div>

  <h3>Install Freeciv 3.2.3 (Mac)</h3>
  <ol>
    <li>Open <strong>Terminal</strong> (search for it in Spotlight)</li>
    <li>If you do not have Homebrew, install it first by pasting this into Terminal:<br>
      <code style="background: #e8e8e8; padding: 4px 8px; border-radius: 4px; display: inline-block; margin: 4px 0;">/bin/bash -c "&#36;(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"</code></li>
    <li>Then install Freeciv 3.2.3:<br>
      <code style="background: #e8e8e8; padding: 4px 8px; border-radius: 4px; display: inline-block; margin: 4px 0;">brew install freeciv</code><br>
      <span style="font-size: 12px; color: #666;">Verify the version: <code>freeciv-gtk4 --version</code> should say <strong>3.2.3</strong></span></li>
    <li>Launch the client by typing:<br>
      <code style="background: #e8e8e8; padding: 4px 8px; border-radius: 4px; display: inline-block; margin: 4px 0;">freeciv-gtk4</code></li>
  </ol>

  <h3>Install Freeciv 3.2.3 (Windows)</h3>
  <ol>
    <li>Download the Freeciv 3.2.3 Windows installer from:<br>
      <a href="https://sourceforge.net/projects/freeciv/files/Freeciv%203.2/3.2.3/Freeciv-3.2.3-msys2-setup.exe/download" style="color: #2c5530; font-weight: bold;">Freeciv-3.2.3-msys2-setup.exe</a><br>
      <span style="font-size: 12px; color: #666;">(Direct link to SourceForge - about 50 MB)</span></li>
    <li>Run the installer and follow the prompts (defaults are fine)</li>
    <li>Launch <strong>Freeciv GTK4 Client</strong> from the Start Menu<br>
      <span style="font-size: 12px; color: #666;">Look for it under "Freeciv 3.2" in your Start Menu programs</span></li>
  </ol>

  <h3>Connect to the Game</h3>
  <ol>
    <li>In Freeciv, click <strong>Connect to Network Game</strong></li>
    <li>Enter the server address: <strong>${SERVER_HOST}</strong></li>
    <li>Port: <strong>5556</strong></li>
    <li>Enter your username and password from above</li>
    <li>You will be automatically assigned to your player</li>
  </ol>

  <h3 style="margin-top: 24px;">Quick Tips</h3>
  <ul>
    <li><strong>Explore early</strong> — send your starting units out to find good city spots</li>
    <li><strong>Build cities</strong> — more cities = more production = more power</li>
    <li><strong>Research techs</strong> — unlock new units, buildings, and wonders</li>
    <li><strong>Click "Turn Done"</strong> when finished — if everyone does it, the next turn starts immediately!</li>
  </ul>

  <div style="background: #25D366; border-radius: 8px; padding: 16px; margin: 20px 0; text-align: center;">
    <p style="color: #fff; margin: 0 0 8px 0; font-size: 15px; font-weight: bold;">Join the WhatsApp group chat for game discussion, diplomacy, and trash talk:</p>
    <a href="https://chat.whatsapp.com/LojPqlgqlBeKg1UEE0nXIr" style="color: #fff; font-size: 16px; font-weight: bold; text-decoration: underline;">Join WhatsApp Group</a>
  </div>

  <div style="background: #1a1a2e; border-radius: 8px; padding: 16px; margin: 20px 0; text-align: center;">
    <p style="color: #ccc; margin: 0 0 8px 0; font-size: 14px;">Game dashboard with live stats, rankings, history &amp; rules:</p>
    <a href="https://${SERVER_HOST}" style="color: #e94560; font-size: 16px; font-weight: bold; text-decoration: none;">${SERVER_HOST}</a>
  </div>

  <p style="color: #666; font-size: 12px; margin-top: 30px;">This is an automated message from the Freeciv server at ${SERVER_HOST}.</p>
</div>
EMAILEOF
)

  echo "$EMAIL_BODY" | curl -s --url "smtps://$SES_SMTP_HOST:465" \
    --ssl-reqd \
    --mail-from "$FROM_EMAIL" \
    --mail-rcpt "$EMAIL" \
    --mail-rcpt "$CC_EMAIL" \
    --user "$SES_SMTP_USER:$SES_SMTP_PASS" \
    --upload-file - 2>/dev/null

  if [ $? -eq 0 ]; then
    echo "  -> Welcome email sent to $EMAIL"
  else
    echo "  -> ERROR sending email to $EMAIL"
  fi
}

send_fifo_cmd() {
  # Send a single command to the running server via FIFO and wait
  local CMD="$1"
  local WAIT="${2:-2}"
  fly ssh console --app "$APP_NAME" -C "sh -c 'echo \"$CMD\" > /tmp/server-input; sleep $WAIT'" 2>&1
}

read_log_tail() {
  # Read last N lines of server log
  local LINES="${1:-5}"
  fly ssh console --app "$APP_NAME" -C "sh -c 'tail -$LINES /data/saves/server.log'" 2>&1
}

add_player_to_game() {
  # Full mid-game player addition:
  # 1. Create player slot
  # 2. Change nation via lua
  # 3. Find a good starting spot (5+ tiles from all players, not tiny island)
  # 4. Place starting units (Settlers + Warriors, NOT stacked)
  # 5. Give starting gold
  # 6. Switch to human control
  local USERNAME="$1"
  local NATION="${2:-}"
  local GOLD="${3:-50}"
  local FIFO=/tmp/server-input
  local LOG=/data/saves/server.log

  # --- Step 1: Create player ---
  echo "  -> Creating in-game player: $USERNAME"
  send_fifo_cmd "create $USERNAME"
  read_log_tail 3

  # --- Step 2: Change nation via lua (if requested) ---
  if [ -n "$NATION" ]; then
    echo "  -> Setting nation to $NATION"
    send_fifo_cmd "lua edit.change_nation(find.player(\"$USERNAME\"), find.nation(\"$NATION\"))"
    read_log_tail 3
  fi

  # --- Step 3: Find starting spot ---
  # Write a shell script to the server that uses multiple small lua commands
  # to find a good spot, then place units there
  echo "  -> Finding starting location (5+ tiles from all players, good land)..."

  # Build the placement script and send it to the server
  # This script:
  #   a) Uses lua to collect occupied positions and write to /tmp/occ.txt
  #   b) Uses lua to scan map for best spot and write to /tmp/spot.txt
  #   c) Uses lua to create units and set gold
  cat > /tmp/add_player_server.sh << SERVEOF
#!/bin/sh
FIFO=/tmp/server-input
LOG=/data/saves/server.log
USERNAME="$USERNAME"
GOLD="$GOLD"

# Step A: Collect all occupied positions (cities + units from other players)
echo 'lua local r=""; for p in players_iterate() do if p.name ~= "${USERNAME}" then for c in p:cities_iterate() do r=r..c.tile.x..","..c.tile.y.." " end; for u in p:units_iterate() do r=r..u.tile.x..","..u.tile.y.." " end end end; log.normal("OCC:"..r)' > \$FIFO
sleep 3

# Extract occupied positions from log
OCC_LINE=\$(grep "OCC:" \$LOG | tail -1 | sed 's/.*OCC://')
echo "Occupied positions: \$OCC_LINE"

# Step B: Use lua to scan map and find best spot
# We pass occupied positions as a lua table literal built from the shell variable
# Build lua table entries from OCC_LINE
OCC_TABLE=""
for pos in \$OCC_LINE; do
  X=\$(echo "\$pos" | cut -d, -f1)
  Y=\$(echo "\$pos" | cut -d, -f2)
  if [ -n "\$X" ] && [ -n "\$Y" ]; then
    OCC_TABLE="\${OCC_TABLE}[\${X}*1000+\${Y}]=1,"
  fi
done

echo "lua local occ={${OCC_TABLE}}; local mx=70; local my=140; local bx,by,bs=-1,-1,-1; for x=0,mx-1 do for y=0,my-1 do local t=find.tile(x,y); if t then local n=t.terrain:rule_name(); if n~='Ocean' and n~='Lake' and n~='Inaccessible' and n~='Mountains' and not t.city then local md=999; for k,_ in pairs(occ) do local cx=math.floor(k/1000); local cy=k%1000; local dx=math.abs(x-cx); if dx>mx/2 then dx=mx-dx end; local dy=math.abs(y-cy); if dy>my/2 then dy=my-dy end; local d=math.max(dx,dy); if d<md then md=d end end; if md>=5 then local lc=0; local sc=0; for a in t:square_iterate(3) do local an=a.terrain:rule_name(); if an~='Ocean' and an~='Lake' and an~='Inaccessible' then lc=lc+1 end; if an=='Grassland' or an=='Plains' then sc=sc+3 elseif an=='Forest' or an=='Hills' then sc=sc+2 end end; if lc>=15 and sc>bs then bs=sc; bx=x; by=y end end end end end end; log.normal(string.format('BESTSPOT:%d,%d,%d',bx,by,bs))" > \$FIFO
sleep 8

# Extract best spot
SPOT_LINE=\$(grep "BESTSPOT:" \$LOG | tail -1 | sed 's/.*BESTSPOT://')
SPOT_X=\$(echo "\$SPOT_LINE" | cut -d, -f1)
SPOT_Y=\$(echo "\$SPOT_LINE" | cut -d, -f2)
SPOT_SCORE=\$(echo "\$SPOT_LINE" | cut -d, -f3)
echo "Best spot: (\$SPOT_X, \$SPOT_Y) score=\$SPOT_SCORE"

if [ "\$SPOT_X" = "-1" ] || [ -z "\$SPOT_X" ]; then
  echo "ERROR: Could not find a suitable starting spot!"
  exit 1
fi

# Step C: Place starting units (Settlers at spot, Warriors on adjacent tile)
# Use edit.create_unit to place them. Warriors go 1 tile east (or next valid land tile)
echo "lua local p=find.player('${USERNAME}'); local t=find.tile(\$SPOT_X,\$SPOT_Y); edit.create_unit(p,t,find.unit_type('Settlers'),1,nil,0); local placed=false; for adj in t:square_iterate(1) do if adj~=t and not placed then local n=adj.terrain:rule_name(); if n~='Ocean' and n~='Lake' and n~='Inaccessible' and n~='Mountains' then edit.create_unit(p,adj,find.unit_type('Warriors'),1,nil,0); placed=true end end end; if not placed then edit.create_unit(p,t,find.unit_type('Warriors'),1,nil,0) end; log.normal('UNITS_PLACED')" > \$FIFO
sleep 3

# Step D: Set starting gold
echo "lua local p=find.player('${USERNAME}'); p.gold=\$GOLD; log.normal('GOLD_SET:'..p.gold)" > \$FIFO
sleep 2

# Step E: Switch to human control
echo "aitoggle ${USERNAME}" > \$FIFO
sleep 2

# Verify
grep -E "BESTSPOT|UNITS_PLACED|GOLD_SET|aitoggle|controls" \$LOG | tail -6
SERVEOF

  # Send and run on server
  cat /tmp/add_player_server.sh | base64 | fly ssh console --app "$APP_NAME" -C "sh -c 'base64 -d > /tmp/add_player_server.sh && chmod +x /tmp/add_player_server.sh && sh /tmp/add_player_server.sh'" 2>&1

  echo "  -> Player setup complete"
}

create_and_notify() {
  local USERNAME="$1"
  local PASSWORD="$2"
  local EMAIL="$3"

  create_player_remote "$USERNAME" "$PASSWORD" "$EMAIL"
  if [ $? -eq 0 ]; then
    send_welcome_email "$USERNAME" "$PASSWORD" "$EMAIL"
  fi
  echo ""
}

wait_for_db() {
  echo "Checking database exists (server must be running first)..."
  local RESULT
  RESULT=$(fly ssh console --app "$APP_NAME" -C "sqlite3 $DB_PATH \"SELECT count(*) FROM sqlite_master WHERE type='table' AND name='fcdb_auth';\"" 2>&1)
  if echo "$RESULT" | grep -q "^1$"; then
    echo "  -> Database ready"
    return 0
  else
    echo "  -> ERROR: Database not ready. Make sure the Freeciv server has started at least once."
    echo "     The server creates the auth database on first startup."
    echo "     Try: fly apps restart $APP_NAME"
    return 1
  fi
}

# ============================================================
# Commands
# ============================================================

case "${1:-}" in
  add)
    if [ $# -lt 4 ]; then
      echo "Usage: $0 add <username> <password> <email> [nation] [gold]"
      echo ""
      echo "Adds a player to a RUNNING game. This does everything:"
      echo "  1. Creates auth entry in the database"
      echo "  2. Creates the player in the running game"
      echo "  3. Sets nation via lua (if specified)"
      echo "  4. Finds a good starting spot (5+ tiles from all players, not tiny island)"
      echo "  5. Places starting units (Settlers + Warriors, not stacked)"
      echo "  6. Sets starting gold (default: 50)"
      echo "  7. Switches to human control"
      echo "  8. Sends welcome email"
      echo ""
      echo "Remember to also add them to the PLAYERS array in this script,"
      echo "longturn.serv, and the aitoggle list in start.sh for future deploys."
      exit 1
    fi
    ADD_USER="$2"
    ADD_PASS="$3"
    ADD_EMAIL="$4"
    ADD_NATION="${5:-}"
    ADD_GOLD="${6:-50}"

    echo "========================================"
    echo "Adding player: $ADD_USER"
    echo "  Email:  $ADD_EMAIL"
    echo "  Nation: ${ADD_NATION:-random}"
    echo "  Gold:   $ADD_GOLD"
    echo "========================================"

    wait_for_db || exit 1

    # Step 1: DB auth
    create_player_remote "$ADD_USER" "$ADD_PASS" "$ADD_EMAIL"
    if [ $? -ne 0 ]; then
      echo "FAILED: Could not create DB entry"
      exit 1
    fi

    # Step 2-6: In-game creation (create, nation, find spot, place units, gold, aitoggle)
    add_player_to_game "$ADD_USER" "$ADD_NATION" "$ADD_GOLD"

    # Step 7: Welcome email
    send_welcome_email "$ADD_USER" "$ADD_PASS" "$ADD_EMAIL"

    echo ""
    echo "Done! Player $ADD_USER added to running game."
    echo ""
    echo "REMINDER: Update these files for future deploys:"
    echo "  - manage_players.sh  (PLAYERS array)"
    echo "  - longturn.serv      (create + playernation)"
    echo "  - start.sh           (aitoggle list)"
    ;;

  create)
    if [ $# -ne 4 ]; then
      echo "Usage: $0 create <username> <password> <email>"
      exit 1
    fi
    wait_for_db || exit 1
    create_and_notify "$2" "$3" "$4"
    ;;

  create-all)
    echo "Creating all players..."
    echo "========================"
    wait_for_db || exit 1
    for PLAYER in "${PLAYERS[@]}"; do
      IFS=':' read -r USERNAME PASSWORD EMAIL NATION <<< "$PLAYER"
      create_and_notify "$USERNAME" "$PASSWORD" "$EMAIL"
    done
    echo "========================"
    echo "Done! All players created and notified."
    ;;

  list)
    echo "Players on server:"
    fly ssh console --app "$APP_NAME" -C "sqlite3 -header -column $DB_PATH \"SELECT id, name, email, datetime(createtime, 'unixepoch') as created, logincount FROM fcdb_auth;\"" 2>&1
    ;;

  reset)
    echo "WARNING: This will delete ALL players and recreate from the PLAYERS list."
    read -p "Are you sure? (y/N): " CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
      echo "Aborted."
      exit 0
    fi
    echo "Resetting player database..."
    fly ssh console --app "$APP_NAME" -C "sqlite3 $DB_PATH \"DELETE FROM fcdb_auth; DELETE FROM fcdb_log;\"" 2>&1
    wait_for_db || exit 1
    for PLAYER in "${PLAYERS[@]}"; do
      IFS=':' read -r USERNAME PASSWORD EMAIL NATION <<< "$PLAYER"
      create_and_notify "$USERNAME" "$PASSWORD" "$EMAIL"
    done
    echo "========================"
    echo "Done! All players recreated and notified."
    ;;

  *)
    echo "Freeciv Player Management"
    echo ""
    echo "Usage:"
    echo "  $0 add <user> <pass> <email> [nation]     Add player to RUNNING game (DB + in-game + email)"
    echo "  $0 create <username> <password> <email>    Create DB auth + send email (pre-game only)"
    echo "  $0 create-all                              Create all players from PLAYERS list"
    echo "  $0 list                                    List all players"
    echo "  $0 reset                                   Delete all and recreate from PLAYERS list"
    echo ""
    echo "Use 'add' for mid-game player additions. Use 'create' for pre-game setup."
    echo "Edit the PLAYERS array at the top of this script to manage the player list."
    ;;
esac
