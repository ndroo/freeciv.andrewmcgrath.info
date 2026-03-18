#!/bin/bash
# Change a player's gold on the running Freeciv server
#
# Usage:
#   ./change_gold.sh <player_name> <amount>
#   ./change_gold.sh DetectiveG 50      # add 50 gold
#   ./change_gold.sh DetectiveG -100    # remove 100 gold
#
# Player names (case-insensitive match):
#   shazow(0) hyfen(1) blakkout(2) jess(3) andrew(4) jamsem24(5)
#   minikeg(6) tracymakes(7) ihop(8) shogun(9) kimjongboom(10)
#   kroony(11) tankerjon(12) peter(13) lion(14) DetectiveG(15)

APP_NAME="freeciv-longturn"

if [ $# -ne 2 ]; then
  echo "Usage: $0 <player_name> <amount>"
  echo "Example: $0 DetectiveG 50"
  exit 1
fi

PLAYER_NAME="$1"
AMOUNT="$2"

# Map player names to IDs (case-insensitive)
declare -A PLAYER_IDS
PLAYER_IDS=(
  [shazow]=0 [hyfen]=1 [blakkout]=2 [jess]=3 [andrew]=4
  [jamsem24]=5 [minikeg]=6 [tracymakes]=7 [ihop]=8 [shogun]=9
  [kimjongboom]=10 [kroony]=11 [tankerjon]=12 [peter]=13
  [lion]=14 [detectiveg]=15
)

LOWER_NAME=$(echo "$PLAYER_NAME" | tr '[:upper:]' '[:lower:]')
PLAYER_ID="${PLAYER_IDS[$LOWER_NAME]}"

if [ -z "$PLAYER_ID" ]; then
  echo "Error: Unknown player '$PLAYER_NAME'"
  echo "Valid players: ${!PLAYER_IDS[*]}"
  exit 1
fi

if ! [[ "$AMOUNT" =~ ^-?[0-9]+$ ]]; then
  echo "Error: Amount must be an integer (e.g. 50 or -100)"
  exit 1
fi

echo "Changing gold for $PLAYER_NAME (player $PLAYER_ID) by $AMOUNT..."

# Write the lua command to a temp file to avoid escaping hell
fly ssh console --app "$APP_NAME" -C "sh -c 'echo \"lua edit.change_gold(find.player($PLAYER_ID),$AMOUNT)\" > /tmp/cmd.txt && cat /tmp/cmd.txt > /tmp/server-input'"

sleep 2

# Check server log for errors
fly ssh console --app "$APP_NAME" -C "sh -c 'tail -3 /data/saves/server.log'"

echo ""
echo "Done. Use './change_gold.sh $PLAYER_NAME 0' and check the save to verify."
