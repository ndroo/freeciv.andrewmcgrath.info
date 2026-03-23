#!/bin/bash
# =============================================================================
# Generates per-player dashboard JSON files from save files.
# Each player gets a personal timeline of events + current state overview.
#
# Usage:
#   ./generate_dashboard.sh                    # incremental (process new turns only)
#   ./generate_dashboard.sh --rebuild          # full rebuild from all saves
#   ./generate_dashboard.sh /path/to/saves     # custom save directory
#
# In incremental mode, only processes turns not yet in the dashboard files,
# plus always re-processes the current (latest) turn for live updates.
#
# Output: dashboard/{playername}.json in the save directory
# =============================================================================
set -eu

SAVE_DIR="/data/saves"
REBUILD=false

for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=true ;;
    *) SAVE_DIR="$arg" ;;
  esac
done

DASHBOARD_DIR="${SAVE_DIR}/dashboard"
mkdir -p "$DASHBOARD_DIR"

# ---------------------------------------------------------------------------
# Parse lookup vectors from a save file (improvement names, tech names)
# Uses python3 csv module for proper quoted-CSV parsing
# ---------------------------------------------------------------------------
parse_vectors() {
  local savefile="$1"

  # Parse into JSON arrays for reliable lookup
  IMP_VECTOR_JSON=$(grep '^improvement_vector=' "$savefile" | sed 's/^improvement_vector=//' | python3 -c "
import csv, json, sys
reader = csv.reader(sys.stdin)
for row in reader:
    print(json.dumps(row))
" 2>/dev/null || echo "[]")

  TECH_VECTOR_JSON=$(grep '^technology_vector=' "$savefile" | sed 's/^technology_vector=//' | python3 -c "
import csv, json, sys
reader = csv.reader(sys.stdin)
for row in reader:
    print(json.dumps(row))
" 2>/dev/null || echo "[]")
}

# ---------------------------------------------------------------------------
# Decode a bitmask using a vector JSON array
# Returns JSON array of names where bit is 1
# ---------------------------------------------------------------------------
decode_bitmask() {
  local bitmask="$1"
  local vector_json="$2"

  echo "$vector_json" | jq -c --arg bitmask "$bitmask" '
    [to_entries[] | select(
      ($bitmask[.key:.key+1] == "1") and .value != "A_NONE" and .value != ""
    ) | .value]
  '
}

# ---------------------------------------------------------------------------
# Extract player data from a decompressed save file
# Outputs JSON object with player state for one player
# ---------------------------------------------------------------------------
extract_player_data() {
  local savefile="$1"
  local player_username="$2"

  # Find player section
  local pline
  pline=$(grep -ni "username=\"${player_username}\"" "$savefile" 2>/dev/null | head -1 | cut -d: -f1)
  [ -z "$pline" ] && return 1

  # Find player index (the [playerN] section number)
  local player_idx
  player_idx=$(awk -v pline="$pline" 'NR<pline && /^\[player[0-9]/' "$savefile" | tail -1 | sed 's/\[player\([0-9]*\)\]/\1/')
  [ -z "$player_idx" ] && return 1

  # Basic attributes
  local name nation government gold is_alive
  name=$(awk -v start="$pline" 'NR>=start-5 && NR<=start+5 && /^name=/{gsub(/^name="/,""); gsub(/"$/,""); print; exit}' "$savefile")
  nation=$(awk -v start="$pline" 'NR>=start-20 && NR<=start && /^nation=/{gsub(/^nation="/,""); gsub(/"$/,""); print; exit}' "$savefile")
  government=$(awk -v start="$pline" 'NR>=start && /^government_name=/{gsub(/^government_name="/,""); gsub(/"$/,""); print; exit}' "$savefile")
  gold=$(awk -v start="$pline" 'NR>=start && /^gold=/{gsub(/^gold=/,""); print; exit}' "$savefile")
  is_alive=$(awk -v start="$pline" 'NR>=start && /^is_alive=/{gsub(/^is_alive=/,""); print; exit}' "$savefile")

  # Score
  local score_section score
  score_section=$(grep -n "^\[score${player_idx}\]" "$savefile" | head -1 | cut -d: -f1)
  if [ -n "$score_section" ]; then
    score=$(awk -v start="$score_section" 'NR>start && /^total=/{gsub(/^total=/,""); print; exit}' "$savefile")
  fi
  score="${score:-0}"

  # Units — extract id and type
  local units_json="[]"
  local unit_data
  unit_data=$(awk -v start="$pline" '
    NR>=start && /^u=\{/ { found=1; next }
    found && /^\}/ { exit }
    found {
      n=split($0, a, ",")
      id=a[1]
      gsub(/"/, "", a[9])
      type=a[9]
      born=a[19]
      hp=a[7]
      vet=a[6]
      printf "%s|%s|%s|%s|%s\n", id, type, born, hp, vet
    }
  ' "$savefile")

  # Build units JSON
  if [ -n "$unit_data" ]; then
    units_json=$(echo "$unit_data" | jq -R -s '
      split("\n") | map(select(length > 0)) | map(
        split("|") | {id: .[0]|tonumber, type: .[1], born: .[2]|tonumber, hp: .[3]|tonumber, veteran: (.[4]|tonumber > 0)}
      )
    ')
  fi

  # Unit type counts
  local unit_types_json="{}"
  if [ -n "$unit_data" ]; then
    unit_types_json=$(echo "$unit_data" | cut -d'|' -f2 | sort | uniq -c | awk '{printf "%s|%s\n", $2, $1}' | jq -R -s '
      split("\n") | map(select(length > 0)) | map(split("|")) | map({(.[0]): (.[1]|tonumber)}) | add // {}
    ')
  fi

  # Cities — extract details using python3 for proper CSV parsing
  local cities_json="[]"

  # Get the city header and data rows
  local city_block
  city_block=$(awk -v start="$pline" '
    NR>=start && /^c=\{/ { found=1; print; next }
    found && /^\}/ { exit }
    found { print }
  ' "$savefile")

  if [ -n "$city_block" ]; then
    cities_json=$(echo "$city_block" | python3 -c "
import csv, json, sys

lines = sys.stdin.read().strip().split('\n')
if not lines:
    print('[]')
    sys.exit(0)

# Parse header
header_line = lines[0]
# Header is c={\"field1\",\"field2\",...}  — strip c={ and }
header_str = header_line.replace('c={', '').rstrip('}')
header = list(csv.reader([header_str]))[0]

# Find field indices
def idx(name):
    try: return header.index(name)
    except ValueError: return -1

i_name = idx('name')
i_size = idx('size')
i_building_name = idx('currently_building_name')
i_improvements = idx('improvements')
i_turn_founded = idx('turn_founded')

cities = []
for line in lines[1:]:
    row = list(csv.reader([line]))[0]
    if len(row) < max(i_name, i_size, i_building_name, i_improvements, i_turn_founded) + 1:
        continue
    imp_bitmask = row[i_improvements] if i_improvements >= 0 else ''
    cities.append({
        'name': row[i_name] if i_name >= 0 else '',
        'size': int(row[i_size]) if i_size >= 0 else 0,
        'building': row[i_building_name] if i_building_name >= 0 else '',
        'improvements_bitmask': imp_bitmask,
        'turn_founded': int(row[i_turn_founded]) if i_turn_founded >= 0 else 0
    })
print(json.dumps(cities))
" 2>/dev/null || echo "[]")

    # Decode improvement bitmasks to names
    cities_json=$(echo "$cities_json" | jq -c --argjson imp_vec "$IMP_VECTOR_JSON" '
      [.[] | . + {
        improvements: (
          .improvements_bitmask as $bm |
          [$imp_vec | to_entries[] | select(
            ($bm[.key:.key+1] == "1") and .value != "" and .value != "A_NONE"
          ) | .value]
        )
      } | del(.improvements_bitmask)]
    ')
  fi

  # Research — techs (use python3 CSV parsing for reliability)
  local research_line techs_count researching goal techs_json
  research_line=$(awk '/^\[research\]/,/^\}/' "$savefile" | sed -n '/^r={/,/^}/p' | grep "^${player_idx},")
  if [ -n "$research_line" ]; then
    local research_parsed
    research_parsed=$(echo "$research_line" | python3 -c "
import csv, json, sys
# Header: number,goal_name,techs,futuretech,bulbs_before,saved_name,bulbs,now_name,free_bulbs,done
row = list(csv.reader(sys.stdin))[0]
print(json.dumps({
    'techs_count': int(row[2]),
    'goal': row[1],
    'researching': row[7],
    'done_bitmask': row[9]
}))
" 2>/dev/null || echo '{}')
    techs_count=$(echo "$research_parsed" | jq -r '.techs_count // 0')
    researching=$(echo "$research_parsed" | jq -r '.researching // ""')
    goal=$(echo "$research_parsed" | jq -r '.goal // ""')
    local done_bitmask
    done_bitmask=$(echo "$research_parsed" | jq -r '.done_bitmask // ""')
    techs_json=$(decode_bitmask "$done_bitmask" "$TECH_VECTOR_JSON")
  else
    techs_count=0
    researching=""
    goal=""
    techs_json="[]"
  fi

  # Diplomacy — extract relationships with other players
  # Rows are ordered by opponent index (0, 1, 2, ...) with no index field
  local diplo_json="[]"

  # First build a player index lookup (idx -> name, nation)
  local player_lookup
  player_lookup=$(awk '
    /^\[player[0-9]/ { idx=$0; gsub(/[^0-9]/,"",idx); name=""; nation="" }
    /^name=/ { name=$0; gsub(/^name="/,"",name); gsub(/"$/,"",name) }
    /^nation=/ { nation=$0; gsub(/^nation="/,"",nation); gsub(/"$/,"",nation); if(name!="") print idx"|"name"|"nation }
  ' "$savefile")

  # Extract diplstate rows with their implicit index
  local diplo_rows
  diplo_rows=$(awk -v start="$pline" '
    NR>=start && /^diplstate=\{/ { found=1; idx=0; next }
    found && /^\}/ { exit }
    found {
      gsub(/"/, "", $0)
      split($0, a, ",")
      status = a[1]
      contact_turn = a[3]
      if (status != "Never met") {
        print idx"|"status"|"contact_turn
      }
      idx++
    }
  ' "$savefile")

  if [ -n "$diplo_rows" ]; then
    diplo_json=$(echo "$diplo_rows" | while IFS='|' read -r pidx dstatus dcontact; do
      [ "$pidx" = "$player_idx" ] && continue
      local pinfo
      pinfo=$(echo "$player_lookup" | grep "^${pidx}|" | head -1)
      [ -z "$pinfo" ] && continue
      local pname pnation
      pname=$(echo "$pinfo" | cut -d'|' -f2)
      pnation=$(echo "$pinfo" | cut -d'|' -f3)
      printf '{"player":"%s","nation":"%s","status":"%s","first_contact_turn":%s}\n' "$pname" "$pnation" "$dstatus" "${dcontact:-0}"
    done | jq -s '.' 2>/dev/null || echo "[]")
  fi

  # Output the full player state JSON
  jq -n \
    --arg name "$name" \
    --arg nation "$nation" \
    --arg gov "${government:-Despotism}" \
    --argjson gold "${gold:-0}" \
    --argjson score "$score" \
    --arg alive "${is_alive:-TRUE}" \
    --argjson techs_count "${techs_count:-0}" \
    --arg researching "${researching:-}" \
    --arg goal "${goal:-}" \
    --argjson techs "$techs_json" \
    --argjson cities "$cities_json" \
    --argjson units "$units_json" \
    --argjson unit_types "$unit_types_json" \
    --argjson diplomacy "$diplo_json" \
    '{
      name: $name, nation: $nation, government: $gov,
      gold: $gold, score: $score, is_alive: ($alive == "TRUE"),
      techs_count: $techs_count, researching: $researching, goal: $goal,
      techs: $techs, cities: $cities, units: $units,
      unit_types: $unit_types, diplomacy: $diplomacy
    }'
}

# ---------------------------------------------------------------------------
# Diff two player states and produce timeline events
# ---------------------------------------------------------------------------
diff_player_states() {
  local prev_json="$1"
  local curr_json="$2"
  local turn="$3"
  local year="$4"

  local events="[]"

  # --- Unit diffs (built/lost) ---
  local new_units lost_units
  new_units=$(jq -n --argjson prev "$prev_json" --argjson curr "$curr_json" '
    ($curr.units | map(.id) | sort) - ($prev.units | map(.id) | sort) |
    . as $new_ids | $curr.units | map(select(.id as $id | $new_ids | index($id)))
  ')
  lost_units=$(jq -n --argjson prev "$prev_json" --argjson curr "$curr_json" '
    ($prev.units | map(.id) | sort) - ($curr.units | map(.id) | sort) |
    . as $lost_ids | $prev.units | map(select(.id as $id | $lost_ids | index($id)))
  ')

  # Add unit_built events
  events=$(echo "$new_units" | jq --argjson events "$events" '
    reduce .[] as $u ($events;
      . + [{"type": "unit_built", "detail": ($u.type + " built")}]
    )
  ')

  # Add unit_lost events
  events=$(echo "$lost_units" | jq --argjson events "$events" '
    reduce .[] as $u ($events;
      . + [{"type": "unit_lost", "detail": ($u.type + " lost")}]
    )
  ')

  # --- City diffs (founded) ---
  local new_cities
  new_cities=$(jq -n --argjson prev "$prev_json" --argjson curr "$curr_json" '
    ($curr.cities | map(.name)) - ($prev.cities | map(.name))
  ')
  events=$(echo "$new_cities" | jq --argjson events "$events" '
    reduce .[] as $c ($events;
      . + [{"type": "city_founded", "detail": ("Founded " + $c)}]
    )
  ')

  # --- Building diffs (per city) ---
  events=$(jq -n --argjson prev "$prev_json" --argjson curr "$curr_json" --argjson events "$events" '
    $events + [
      $curr.cities[] as $city |
      ($prev.cities | map(select(.name == $city.name)) | .[0]) as $prev_city |
      if $prev_city then
        ($city.improvements - $prev_city.improvements)[] |
        {"type": "building_completed", "detail": (. + " completed in " + $city.name)}
      else
        empty
      end
    ]
  ')

  # --- Tech diffs ---
  local new_techs
  new_techs=$(jq -n --argjson prev "$prev_json" --argjson curr "$curr_json" '
    ($curr.techs) - ($prev.techs)
  ')
  events=$(echo "$new_techs" | jq --argjson events "$events" '
    reduce .[] as $t ($events;
      . + [{"type": "tech_researched", "detail": ("Learned " + $t)}]
    )
  ')

  # --- Government change ---
  local gov_changed
  gov_changed=$(jq -n --argjson prev "$prev_json" --argjson curr "$curr_json" '
    if $prev.government != $curr.government then
      "Changed from " + $prev.government + " to " + $curr.government
    else null end
  ')
  if [ "$gov_changed" != "null" ]; then
    events=$(jq -n --argjson events "$events" --arg detail "$(echo "$gov_changed" | tr -d '"')" '
      $events + [{"type": "government_changed", "detail": $detail}]
    ')
  fi

  # --- Diplomacy changes ---
  events=$(jq -n --argjson prev "$prev_json" --argjson curr "$curr_json" --argjson events "$events" '
    $events + [
      $curr.diplomacy[] as $d |
      ($prev.diplomacy | map(select(.player == $d.player)) | .[0]) as $prev_d |
      if $prev_d then
        if $prev_d.status != $d.status then
          {"type": "diplomacy_changed", "detail": ($d.status + " with " + $d.player + " (" + $d.nation + ")")}
        else empty end
      else
        {"type": "diplomacy_changed", "detail": ("First contact with " + $d.player + " (" + $d.nation + ")")}
      end
    ]
  ')

  # --- Score change ---
  local score_delta
  score_delta=$(jq -n --argjson prev "$prev_json" --argjson curr "$curr_json" '
    $curr.score - $prev.score
  ')
  if [ "$score_delta" != "0" ]; then
    events=$(jq -n --argjson events "$events" --argjson delta "$score_delta" --argjson from "$(jq -n --argjson p "$prev_json" '$p.score')" --argjson to "$(jq -n --argjson c "$curr_json" '$c.score')" '
      $events + [{"type": "score_change", "detail": ("Score: " + ($from|tostring) + " → " + ($to|tostring) + " (" + (if $delta > 0 then "+" else "" end) + ($delta|tostring) + ")")}]
    ')
  fi

  echo "$events"
}

# ---------------------------------------------------------------------------
# Main: process all saves and generate per-player dashboards
# ---------------------------------------------------------------------------

echo "[dashboard] Starting dashboard generation from $SAVE_DIR"

# Find all save files — one per turn, latest file wins (matches generate_status_json.sh)
DECOMPRESS=true
SAVE_FILES=$(ls -1 "$SAVE_DIR"/lt-game-*.sav.* 2>/dev/null \
  | sed 's/.*lt-game-\([0-9]*\)[.-].*/\1 &/' \
  | sort -k1 -n -k2 \
  | awk '{latest[$1]=$0} END {for (t in latest) print latest[t]}' \
  | sort -k1 -n) || true

if [ -z "$SAVE_FILES" ]; then
  # For local testing with decompressed .txt files
  SAVE_FILES=$(ls -1 "$SAVE_DIR"/lt-game-*.txt 2>/dev/null \
    | sed 's/.*lt-game-\([0-9]*\)[.-].*/\1 &/' \
    | sort -k1 -n -k2 \
    | awk '{latest[$1]=$0} END {for (t in latest) print latest[t]}' \
    | sort -k1 -n) || true
  DECOMPRESS=false
fi

[ -z "$SAVE_FILES" ] && { echo "[dashboard] No save files found"; exit 0; }

echo "[dashboard] Found $(echo "$SAVE_FILES" | wc -l | tr -d ' ') save files (one per turn)"

# Parse vectors from first save
FIRST_SAVE=$(echo "$SAVE_FILES" | head -1 | awk '{print $2}')
TMPFILE=$(mktemp)
if [ "$DECOMPRESS" = "true" ]; then
  gzip -dc "$FIRST_SAVE" > "$TMPFILE"
  parse_vectors "$TMPFILE"
else
  parse_vectors "$FIRST_SAVE"
fi

# Get list of all player usernames from latest save (excluding barbarians)
LATEST_SAVE=$(echo "$SAVE_FILES" | tail -1 | awk '{print $2}')
if [ "$DECOMPRESS" = "true" ]; then
  gzip -dc "$LATEST_SAVE" > "$TMPFILE"
  PLAYERS=$(grep 'username=' "$TMPFILE" | grep -v 'username=""' | sed 's/username="//;s/"//' | tr '[:upper:]' '[:lower:]' | sort -u)
else
  PLAYERS=$(grep 'username=' "$LATEST_SAVE" | grep -v 'username=""' | sed 's/username="//;s/"//' | tr '[:upper:]' '[:lower:]' | sort -u)
fi

# Filter out non-player entries
PLAYERS=$(echo "$PLAYERS" | grep -v '^$' | grep -v 'ranked_unassigned' | grep -v 'unassigned')
PLAYER_COUNT=$(echo "$PLAYERS" | wc -l | tr -d ' ')
echo "[dashboard] $PLAYER_COUNT players: $(echo $PLAYERS | tr '\n' ' ')"

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR ${TMPFILE:-}" EXIT

LATEST_TURN=$(echo "$SAVE_FILES" | tail -1 | awk '{print $1}')
TOTAL_SAVES=$(echo "$SAVE_FILES" | wc -l | tr -d ' ')
echo "[dashboard] $TOTAL_SAVES save files, latest turn: $LATEST_TURN"

# Pre-decompress all save files once to avoid redundant gzip per player
echo "[dashboard] Pre-decompressing save files..."
mkdir -p "$WORK_DIR/saves"
DECOMPRESSED_LIST=""
save_idx=0
SKIPPED_SAVES=0
echo "$SAVE_FILES" | while read -r file_turn savefile; do
  [ -z "$savefile" ] && continue
  dest="$WORK_DIR/saves/turn-${file_turn}.txt"
  if [ "$DECOMPRESS" = "true" ]; then
    # Skip corrupt/empty save files
    filesize=$(stat -c%s "$savefile" 2>/dev/null || stat -f%z "$savefile" 2>/dev/null || echo 0)
    if [ "$filesize" -lt 100 ] 2>/dev/null; then
      echo "[dashboard] WARNING: skipping $savefile (${filesize} bytes, likely corrupt)"
      continue
    fi
    if ! gzip -dc "$savefile" > "$dest" 2>/dev/null; then
      echo "[dashboard] WARNING: skipping $savefile (decompression failed)"
      rm -f "$dest"
      continue
    fi
  else
    cp "$savefile" "$dest"
  fi
done
echo "[dashboard] Decompressed $TOTAL_SAVES saves"

# Build the list of decompressed files with turn/year info
DECOMPRESSED_LIST=""
for dest in "$WORK_DIR"/saves/turn-*.txt; do
  [ ! -f "$dest" ] && continue
  turn=$(grep '^turn=' "$dest" | head -1 | sed 's/turn=//')
  year=$(grep '^year=' "$dest" | head -1 | sed 's/year=//')
  if [ "$year" -lt 0 ]; then
    year_display="$(echo $year | tr -d '-') BC"
  else
    year_display="$year AD"
  fi
  echo "${turn}|${year_display}|${dest}"
done | sort -t'|' -k1 -n > "$WORK_DIR/decompressed_list"

echo "[dashboard] Save file index ready"

# Parse vectors once (same across all saves)
first_decomp=$(head -1 "$WORK_DIR/decompressed_list" | cut -d'|' -f3)
parse_vectors "$first_decomp"

# ---------------------------------------------------------------------------
# Process one player at a time through all turns, write to disk immediately.
# Run multiple players in parallel (CPU-limited batches).
# Each completed player is written to disk — crash-safe.
# ---------------------------------------------------------------------------
NCPU=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
# Cap at 4 to avoid memory pressure
[ "$NCPU" -gt 4 ] && NCPU=4
echo "[dashboard] Parallelism: $NCPU players at a time"

process_player() {
  local p="$1"
  local outfile="$DASHBOARD_DIR/${p}.json"
  local start_time=$(date +%s)

  # In incremental mode, check if this player is already up to date
  local player_last=0
  if [ "$REBUILD" = "false" ] && [ -f "$outfile" ]; then
    player_last=$(jq -r '.timeline[-1].turn // 0' "$outfile" 2>/dev/null || echo 0)
    if [ "$player_last" -ge "$LATEST_TURN" ] 2>/dev/null; then
      echo "[dashboard]   $p: up to date, refreshing current state only"
      player_last=$((LATEST_TURN - 1))
    fi
  fi

  # Load existing timeline if incremental
  local timeline="[]"
  if [ "$REBUILD" = "false" ] && [ -f "$outfile" ]; then
    timeline=$(jq -c "[.timeline[] | select(.turn <= $((player_last - 1)))]" "$outfile" 2>/dev/null || echo "[]")
  fi

  local prev_state="" curr_state="" nation="" turns_processed=0

  while IFS='|' read -r turn year_display local_file; do
    [ -z "$local_file" ] && continue

    # Skip old turns, but load the one before our start for diffing
    if [ "$turn" -lt "$player_last" ] 2>/dev/null; then
      if [ "$turn" -eq "$((player_last - 1))" ] 2>/dev/null; then
        prev_state=$(extract_player_data "$local_file" "$p" 2>/dev/null || true)
        if [ -z "$prev_state" ]; then
          local cap_p=$(echo "$p" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
          prev_state=$(extract_player_data "$local_file" "$cap_p" 2>/dev/null || true)
        fi
      fi
      continue
    fi

    # Extract current state
    curr_state=$(extract_player_data "$local_file" "$p" 2>/dev/null || true)
    if [ -z "$curr_state" ]; then
      local cap_p=$(echo "$p" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
      curr_state=$(extract_player_data "$local_file" "$cap_p" 2>/dev/null || true)
    fi
    [ -z "$curr_state" ] && continue

    nation=$(echo "$curr_state" | jq -r '.nation')

    # Compute diff
    local events="[]"
    if [ -n "$prev_state" ]; then
      events=$(diff_player_states "$prev_state" "$curr_state" "$turn" "$year_display")
    fi

    # Append to timeline
    timeline=$(echo "$timeline" | jq -c --argjson t "$turn" '[.[] | select(.turn != $t)]')
    timeline=$(jq -n -c \
      --argjson timeline "$timeline" \
      --argjson events "$events" \
      --argjson turn "$turn" \
      --arg year "$year_display" \
      '$timeline + [{"turn": $turn, "year": $year, "events": $events}]')

    prev_state="$curr_state"
    turns_processed=$((turns_processed + 1))
  done < "$WORK_DIR/decompressed_list"

  # Write to disk immediately
  if [ -n "$curr_state" ]; then
    jq -n \
      --arg player "$p" \
      --arg nation "${nation:-}" \
      --argjson current "$curr_state" \
      --argjson timeline "$timeline" \
      '{player: $player, nation: $nation, current: $current, timeline: $timeline}' > "$outfile.tmp"
    mv "$outfile.tmp" "$outfile"
    local event_count=$(echo "$timeline" | jq '[.[].events | length] | add // 0')
    local elapsed=$(( $(date +%s) - start_time ))
    echo "[dashboard]   $p: done — $turns_processed turns, $event_count events, ${elapsed}s"
  else
    echo "[dashboard]   $p: no data found"
  fi
}

BATCH=0
COMPLETED=0
echo "[dashboard] Processing players..."
for p in $PLAYERS; do
  process_player "$p" &
  BATCH=$((BATCH + 1))
  if [ "$BATCH" -ge "$NCPU" ]; then
    wait
    COMPLETED=$((COMPLETED + BATCH))
    echo "[dashboard] Progress: $COMPLETED/$PLAYER_COUNT players complete"
    BATCH=0
  fi
done
wait
COMPLETED=$((COMPLETED + BATCH))
echo "[dashboard] All $COMPLETED players complete"

echo "[dashboard] Done"
