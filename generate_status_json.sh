#!/bin/bash
# Generates status.json (current game state) and maintains history.json
# (append-only per-turn player stats).
#
# Called by cron (every 5min) and directly on turn changes.
#
# Usage:
#   ./generate_status_json.sh                      # live mode (sends FIFO commands)
#   ./generate_status_json.sh --no-live            # skip FIFO interaction (for testing)
#   ./generate_status_json.sh --rebuild-history    # rebuild history.json from all saves
#   ./generate_status_json.sh --rebuild-attendance # rebuild attendance.json from all saves

set -eu

# ---------------------------------------------------------------------------
# Prevent concurrent runs (cron + turn-change triggers can overlap)
# ---------------------------------------------------------------------------
LOCKFILE="/tmp/generate-status.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    echo "[status-json] Another instance is running, skipping"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Configuration (env vars with defaults)
# ---------------------------------------------------------------------------
SAVE_DIR="${SAVE_DIR:-/data/saves}"
WEBROOT="${WEBROOT:-/opt/freeciv/www}"
DB_PATH="${DB_PATH:-/data/saves/freeciv.sqlite}"
SERVER_HOST="${SERVER_HOST:-freeciv.andrewmcgrath.info}"
LOGFILE="${LOGFILE:-/data/saves/server.log}"
SERVER_PORT=5556
JOIN_FORM="https://docs.google.com/forms/d/e/1FAIpQLSdtCLEfuwF_o4Sgdc-UT1X7zRsqigJHeRKxAELmlJug0KHwlw/viewform?usp=dialog"
GAME_VERSION="3.2.3"
RULESET="civ2civ3"
HISTORY_FILE="$SAVE_DIR/history.json"
ATTENDANCE_FILE="$SAVE_DIR/attendance.json"

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
NO_LIVE=false
REBUILD_HISTORY=false
REBUILD_ATTENDANCE=false
for arg in "$@"; do
  case "$arg" in
    --no-live) NO_LIVE=true ;;
    --rebuild-history) REBUILD_HISTORY=true ;;
    --rebuild-attendance) REBUILD_ATTENDANCE=true ;;
  esac
done

# ---------------------------------------------------------------------------
# Temp file cleanup
# ---------------------------------------------------------------------------
TMPFILES=()
cleanup() {
  rm -f "${TMPFILES[@]}" 2>/dev/null || true
}
trap cleanup EXIT

make_tmp() {
  local f
  f=$(mktemp /tmp/freeciv-hist-XXXXXX)
  TMPFILES+=("$f")
  echo "$f"
}

# ---------------------------------------------------------------------------
# Decompress a save file into a temp file. Prints temp path.
# ---------------------------------------------------------------------------
decompress_save() {
  local save_path="$1"
  local tmp
  tmp=$(make_tmp)
  case "$save_path" in
    *.xz)  xz -dc "$save_path" > "$tmp" 2>/dev/null ;;
    *.bz2) bzip2 -dc "$save_path" > "$tmp" 2>/dev/null ;;
    *.gz)  gzip -dc "$save_path" > "$tmp" 2>/dev/null ;;
    *.zst) zstd -dc "$save_path" > "$tmp" 2>/dev/null ;;
    *)     cp "$save_path" "$tmp" ;;
  esac
  if [ -s "$tmp" ]; then
    echo "$tmp"
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Build a history entry JSON from a decompressed save tmpfile
# ---------------------------------------------------------------------------
build_history_entry() {
  local tmpfile="$1"
  local game_section turn year num_players
  game_section=$(sed -n '/^\[game\]/,/^\[/p' "$tmpfile" | head -30)
  turn=$(echo "$game_section" | grep '^turn=' | head -1 | sed 's/turn=//')
  year=$(echo "$game_section" | grep '^year=' | head -1 | sed 's/year=//')
  num_players=$(grep -c '^\[player[0-9]' "$tmpfile" 2>/dev/null || echo 0)

  local player_json_parts=""
  for i in $(seq 0 $((num_players - 1))); do
    local section score_section p_name p_nation p_gold p_ncities p_nunits p_gov p_alive p_score
    section=$(sed -n "/^\[player${i}\]/,/^\[/p" "$tmpfile" | head -150)
    p_name=$(echo "$section" | grep '^name=' | head -1 | sed 's/name="//' | sed 's/"//')
    p_nation=$(echo "$section" | grep '^nation=' | head -1 | sed 's/nation="//' | sed 's/"//')

    # Filter barbarians and animals
    case "$p_name" in *arbarian*|Lion|Pirates) continue ;; esac
    case "$p_nation" in *animal*) continue ;; esac

    p_gold=$(echo "$section" | grep '^gold=' | head -1 | sed 's/gold=//')
    p_ncities=$(echo "$section" | grep '^ncities=' | head -1 | sed 's/ncities=//')
    p_nunits=$(echo "$section" | grep '^nunits=' | head -1 | sed 's/nunits=//')
    p_gov=$(echo "$section" | grep '^government_name=' | head -1 | sed 's/government_name="//' | sed 's/"//')
    p_alive=$(echo "$section" | grep '^is_alive=' | head -1 | sed 's/is_alive=//')

    score_section=$(sed -n "/^\[score${i}\]/,/^\[/p" "$tmpfile" | head -30)
    p_score=$(echo "$score_section" | grep '^total=' | head -1 | sed 's/total=//')
    [ -z "$p_score" ] && p_score="0"

    # Tech count from [research] section
    local p_techs="0"
    local research_line
    research_line=$(sed -n '/^\[research\]/,/^\[/p' "$tmpfile" | grep "^${i}," | head -1)
    if [ -n "$research_line" ]; then
      p_techs=$(echo "$research_line" | cut -d',' -f3)
    fi

    # Unit type counts from the full player section
    local full_section unit_types_json="{}"
    full_section=$(sed -n "/^\[player${i}\]/,/^\[/p" "$tmpfile")
    local unit_lines
    unit_lines=$(echo "$full_section" | grep -E '^[0-9]+,' | grep -oE '"[A-Z][^"]*"' | head -1000)
    # unit rows have type_by_name as the 9th field — extract it
    # Each unit row: id,x,y,"facing",nationality,veteran,hp,homecity,"type_by_name",...
    while IFS= read -r uline; do
      # Extract 9th comma-separated field (type_by_name)
      local utype
      utype=$(echo "$uline" | awk -F',' '{gsub(/"/, "", $9); print $9}')
      [ -z "$utype" ] && continue
      unit_types_json=$(echo "$unit_types_json" | jq --arg t "$utype" '.[$t] = ((.[$t] // 0) + 1)')
    done < <(echo "$full_section" | sed -n '/^u={/,/^}/p' | grep -E '^[0-9]+,')

    local p_nation_cap="${p_nation^}"
    local local_alive="true"
    [ "$p_alive" = "FALSE" ] && local_alive="false"

    local player_obj
    player_obj=$(jq -n \
      --argjson score "${p_score:-0}" \
      --argjson cities "${p_ncities:-0}" \
      --argjson units "${p_nunits:-0}" \
      --argjson gold "${p_gold:-0}" \
      --argjson techs "${p_techs:-0}" \
      --arg nation "$p_nation_cap" \
      --arg government "${p_gov:-Despotism}" \
      --argjson is_alive "$local_alive" \
      --argjson unit_types "$unit_types_json" \
      '{score: $score, cities: $cities, units: $units, gold: $gold, techs: $techs, nation: $nation, government: $government, is_alive: $is_alive, unit_types: $unit_types}')

    if [ -n "$player_json_parts" ]; then
      player_json_parts="${player_json_parts},"
    fi
    player_json_parts="${player_json_parts}$(jq -n --arg name "$p_name" --argjson obj "$player_obj" '{($name): $obj}' | sed '1d;$d')"
  done

  jq -n \
    --argjson turn "${turn}" \
    --argjson year "${year}" \
    --argjson players "{${player_json_parts}}" \
    '{turn: $turn, year: $year, players: $players}'
}

# ---------------------------------------------------------------------------
# Find all save files sorted by turn number (one per turn, latest file wins)
# ---------------------------------------------------------------------------
SAVE_FILES=$(ls -1 "$SAVE_DIR"/lt-game-*.sav.* 2>/dev/null \
  | sed 's/.*lt-game-\([0-9]*\)[.-].*/\1 &/' \
  | sort -k1 -n -k2 \
  | awk '{latest[$1]=$0} END {for (t in latest) print latest[t]}' \
  | sort -k1 -n) || true

LATEST_SAVE_FILE=$(echo "$SAVE_FILES" | tail -1 | awk '{print $2}')

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
TURN="0"
YEAR="0"
SERVER_STATUS="Offline"
PLAYER_COUNT="0"

# Check if server is running
if [ -f "$LOGFILE" ] && grep -q "Now accepting" "$LOGFILE" 2>/dev/null; then
  SERVER_STATUS="Online"
fi

# Get registered player count (from sqlite or sql dump for testing)
if command -v sqlite3 &>/dev/null && [ -f "$DB_PATH" ]; then
  PLAYER_COUNT=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM fcdb_auth;" 2>/dev/null || echo "0")
fi
if [ "$PLAYER_COUNT" = "0" ] && [ -f "$DB_PATH" ]; then
  # Fallback: count INSERT lines in SQL dump (for testing)
  SQL_COUNT=$(grep -c "^INSERT INTO fcdb_auth" "$DB_PATH" 2>/dev/null || echo "0")
  [ "$SQL_COUNT" -gt 0 ] 2>/dev/null && PLAYER_COUNT="$SQL_COUNT"
fi

# ============================================================================
# History: append-only per-turn stats
# ============================================================================

# Load or initialize history
if [ -f "$HISTORY_FILE" ] && jq . "$HISTORY_FILE" >/dev/null 2>&1; then
  HISTORY_JSON=$(cat "$HISTORY_FILE")
else
  HISTORY_JSON="[]"
fi

if [ "$REBUILD_HISTORY" = "true" ]; then
  # Rebuild from all save files
  echo "[status-json] Rebuilding history from all save files..."
  HISTORY_JSON="[]"
  while read -r turn_num save_path; do
    [ -z "$save_path" ] && continue
    [ ! -f "$save_path" ] && continue
    TMPFILE=$(decompress_save "$save_path") || continue
    ENTRY=$(build_history_entry "$TMPFILE")
    HISTORY_JSON=$(echo "$HISTORY_JSON" | jq --argjson entry "$ENTRY" '. + [$entry]')
    rm -f "$TMPFILE"
  done <<< "$SAVE_FILES"
  echo "$HISTORY_JSON" > "$HISTORY_FILE.tmp"
  mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
  echo "[status-json] Rebuilt history with $(echo "$HISTORY_JSON" | jq 'length') entries"
fi

# Parse latest save file for current turn data
LATEST_TMPFILE=""
if [ -n "${LATEST_SAVE_FILE:-}" ] && [ -f "$LATEST_SAVE_FILE" ]; then
  LATEST_TMPFILE=$(decompress_save "$LATEST_SAVE_FILE") || true
fi

if [ -n "$LATEST_TMPFILE" ] && [ -s "$LATEST_TMPFILE" ]; then
  GAME_SECTION=$(sed -n '/^\[game\]/,/^\[/p' "$LATEST_TMPFILE" | head -30)
  TURN=$(echo "$GAME_SECTION" | grep '^turn=' | head -1 | sed 's/turn=//')
  YEAR=$(echo "$GAME_SECTION" | grep '^year=' | head -1 | sed 's/year=//')

  # Append to history if this turn isn't already there.
  # Quick check: extract turn number from filename to avoid jq/decompression work
  if [ "$REBUILD_HISTORY" = "false" ]; then
    FILENAME_TURN=$(echo "$LATEST_SAVE_FILE" | sed 's/.*lt-game-\([0-9]*\)[.-].*/\1/')
    ALREADY_EXISTS=$(echo "$HISTORY_JSON" | jq --argjson t "${FILENAME_TURN:-$TURN}" '[.[] | select(.turn == $t)] | length')
    if [ "$ALREADY_EXISTS" = "0" ]; then
      ENTRY=$(build_history_entry "$LATEST_TMPFILE")
      HISTORY_JSON=$(echo "$HISTORY_JSON" | jq --argjson entry "$ENTRY" '. + [$entry]')
      echo "$HISTORY_JSON" > "$HISTORY_FILE.tmp"
      mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
    fi
  fi
fi

# Year display
if [ "$YEAR" -lt 0 ] 2>/dev/null; then
  YEAR_DISPLAY="$(echo "$YEAR" | sed 's/-//') BC"
else
  YEAR_DISPLAY="${YEAR:-0} AD"
fi

# Symlink history.json into webroot for HTTP serving
ln -sf "$HISTORY_FILE" "$WEBROOT/history.json"

# ============================================================================
# Attendance: track missed turns per player from all completed save files
# ============================================================================

# Build attendance by scanning all save files except the in-progress turn.
# A player "missed" a turn if phase_done=FALSE in that turn's save.
build_attendance() {
  local attendance_json="{}"
  local completed_saves
  # All saves except the latest (which is the current in-progress turn)
  completed_saves=$(echo "$SAVE_FILES" | sed '$d')

  while read -r turn_num save_path; do
    [ -z "$save_path" ] && continue
    [ ! -f "$save_path" ] && continue
    local tmp
    tmp=$(decompress_save "$save_path") || continue
    local np
    np=$(grep -c '^\[player[0-9]' "$tmp" 2>/dev/null || echo 0)
    for i in $(seq 0 $((np - 1))); do
      local sec pname pnation pdone palive
      sec=$(sed -n "/^\[player${i}\]/,/^\[/p" "$tmp" | head -150)
      pname=$(echo "$sec" | grep '^name=' | head -1 | sed 's/name="//' | sed 's/"//')
      pnation=$(echo "$sec" | grep '^nation=' | head -1 | sed 's/nation="//' | sed 's/"//')

      # Filter barbarians and animals
      case "$pname" in *arbarian*|Lion|Pirates) continue ;; esac
      case "$pnation" in *animal*) continue ;; esac

      palive=$(echo "$sec" | grep '^is_alive=' | head -1 | sed 's/is_alive=//')
      [ "$palive" = "FALSE" ] && continue

      pdone=$(echo "$sec" | grep '^phase_done=' | head -1 | sed 's/phase_done=//')

      # Update attendance: increment total_turns, and missed if not done
      local missed_inc=0
      [ "$pdone" != "TRUE" ] && missed_inc=1

      attendance_json=$(echo "$attendance_json" | jq \
        --arg name "$pname" \
        --argjson turn "$turn_num" \
        --argjson missed_inc "$missed_inc" '
        if .[$name] then
          .[$name].total_turns += 1 |
          .[$name].missed_turns += $missed_inc |
          if $missed_inc == 1 then .[$name].missed += [$turn] else . end
        else
          .[$name] = {
            missed_turns: $missed_inc,
            total_turns: 1,
            missed: (if $missed_inc == 1 then [$turn] else [] end)
          }
        end')
    done
    rm -f "$tmp"
  done <<< "$completed_saves"

  echo "$attendance_json"
}

if [ "$REBUILD_ATTENDANCE" = "true" ] || [ ! -f "$ATTENDANCE_FILE" ] || ! jq . "$ATTENDANCE_FILE" >/dev/null 2>&1; then
  echo "[status-json] Building attendance from all save files..."
  ATTENDANCE_JSON=$(build_attendance)
  echo "$ATTENDANCE_JSON" > "$ATTENDANCE_FILE.tmp"
  mv "$ATTENDANCE_FILE.tmp" "$ATTENDANCE_FILE"
  echo "[status-json] Built attendance for $(echo "$ATTENDANCE_JSON" | jq 'keys | length') players"
else
  # Check if we need to update (new completed turn)
  CURRENT_TURNS=$(echo "$SAVE_FILES" | wc -l | tr -d ' ')
  COMPLETED_TURNS=$((CURRENT_TURNS - 1))
  if [ "$COMPLETED_TURNS" -gt 0 ]; then
    ATTENDANCE_JSON=$(cat "$ATTENDANCE_FILE")
    # Check if the latest completed turn is already tracked
    LATEST_COMPLETED_TURN=$(echo "$SAVE_FILES" | sed '$d' | tail -1 | awk '{print $1}')
    if [ -n "$LATEST_COMPLETED_TURN" ]; then
      ALREADY_TRACKED=$(echo "$ATTENDANCE_JSON" | jq --argjson t "$LATEST_COMPLETED_TURN" '
        [to_entries[].value.missed[] | select(. == $t)] | length > 0 or
        [to_entries[].value.total_turns] | max >= $t' 2>/dev/null || echo "false")
      # Rebuild if max total_turns is less than the number of completed turns
      MAX_TOTAL=$(echo "$ATTENDANCE_JSON" | jq '[to_entries[].value.total_turns] | max // 0' 2>/dev/null || echo "0")
      if [ "$MAX_TOTAL" -lt "$COMPLETED_TURNS" ] 2>/dev/null; then
        echo "[status-json] Attendance out of date, rebuilding..."
        ATTENDANCE_JSON=$(build_attendance)
        echo "$ATTENDANCE_JSON" > "$ATTENDANCE_FILE.tmp"
        mv "$ATTENDANCE_FILE.tmp" "$ATTENDANCE_FILE"
      fi
    fi
  fi
  ATTENDANCE_JSON=$(cat "$ATTENDANCE_FILE")
fi

# Symlink attendance.json into webroot for HTTP serving
ln -sf "$ATTENDANCE_FILE" "$WEBROOT/attendance.json"

# Symlink gazette.json into webroot if it exists
[ -f "$SAVE_DIR/gazette.json" ] && ln -sf "$SAVE_DIR/gazette.json" "$WEBROOT/gazette.json"

# ============================================================================
# Diplomacy: extract relationships from save files
# ============================================================================
DIPLOMACY_FILE="$SAVE_DIR/diplomacy.json"

# Extract diplomacy from a decompressed save file.
# Outputs JSON: { "current": { "Player1|Player2": {"status":"Peace",...}, ...}, "turn": N }
extract_diplomacy() {
  local tmpfile="$1"
  local game_section save_turn np
  game_section=$(sed -n '/^\[game\]/,/^\[/p' "$tmpfile" | head -30)
  save_turn=$(echo "$game_section" | grep '^turn=' | head -1 | sed 's/turn=//')
  save_year=$(echo "$game_section" | grep '^year=' | head -1 | sed 's/year=//')
  np=$(grep -c '^\[player[0-9]' "$tmpfile" 2>/dev/null || echo 0)

  # First pass: get player names and filter barbarians
  local -a pnames
  local -A valid_players
  for i in $(seq 0 $((np - 1))); do
    local sec pname pnation
    sec=$(sed -n "/^\[player${i}\]/,/^\[/p" "$tmpfile" | head -150)
    pname=$(echo "$sec" | grep '^name=' | head -1 | sed 's/name="//' | sed 's/"//')
    pnation=$(echo "$sec" | grep '^nation=' | head -1 | sed 's/nation="//' | sed 's/"//')
    pnames[$i]="$pname"
    case "$pname" in *arbarian*|Lion|Pirates) continue ;; esac
    case "$pnation" in *animal*) continue ;; esac
    valid_players[$i]="1"
  done

  # Second pass: extract diplstate for valid players
  local relationships="[]"
  for i in $(seq 0 $((np - 1))); do
    [ "${valid_players[$i]:-}" != "1" ] && continue
    local sec dipl_block
    sec=$(sed -n "/^\[player${i}\]/,/^\[/p" "$tmpfile")
    # Extract diplstate rows (between diplstate={ and })
    dipl_block=$(echo "$sec" | sed -n '/^diplstate=/,/^\}/p' | tail -n +2 | sed '$d')
    local row=0
    while IFS= read -r line; do
      [ -z "$line" ] && { row=$((row + 1)); continue; }
      # Only process if target is valid and index > current player (avoid duplicates)
      if [ "$row" -gt "$i" ] && [ "${valid_players[$row]:-}" = "1" ]; then
        local status closest first_contact has_reason embassy shared_vision
        status=$(echo "$line" | cut -d',' -f1 | tr -d '"')
        closest=$(echo "$line" | cut -d',' -f2 | tr -d '"')
        first_contact=$(echo "$line" | cut -d',' -f3)
        has_reason=$(echo "$line" | cut -d',' -f5)
        embassy=$(echo "$line" | cut -d',' -f7)
        shared_vision=$(echo "$line" | cut -d',' -f8)

        if [ "$status" != "Never met" ]; then
          local hrc_json="false"
          [ "$has_reason" != "0" ] && hrc_json="true"
          local emb_json="false"
          [ "$embassy" = "TRUE" ] && emb_json="true"
          local sv_json="false"
          [ "$shared_vision" = "TRUE" ] && sv_json="true"

          # Default War state (closest=War) just means "met", not actual combat
          local display_status="$status"
          if [ "$status" = "War" ] && [ "$closest" = "War" ]; then
            display_status="Contact"
          fi

          relationships=$(echo "$relationships" | jq \
            --arg p1 "${pnames[$i]}" \
            --arg p2 "${pnames[$row]}" \
            --arg status "$display_status" \
            --arg closest "$closest" \
            --argjson first_contact "${first_contact:-0}" \
            --argjson has_reason_to_cancel "$hrc_json" \
            --argjson embassy "$emb_json" \
            --argjson shared_vision "$sv_json" \
            '. + [{
              players: [$p1, $p2],
              status: $status,
              closest: $closest,
              first_contact_turn: $first_contact,
              has_reason_to_cancel: $has_reason_to_cancel,
              embassy: $embassy,
              shared_vision: $shared_vision
            }]')
        fi
      fi
      row=$((row + 1))
    done <<< "$dipl_block"
  done

  jq -n \
    --argjson turn "$save_turn" \
    --argjson year "$save_year" \
    --argjson relationships "$relationships" \
    '{turn: $turn, year: $year, relationships: $relationships}'
}

# ---------------------------------------------------------------------------
# Extract combat pairs from a save file's event_cache.
# Returns JSON array of ["name1","name2"] pairs (sorted alphabetically).
# Uses sed/grep/awk for speed — no jq in loops.
# ---------------------------------------------------------------------------
extract_combat_pairs() {
  local tmpfile="$1"
  local np
  np=$(grep -c '^\[player[0-9]' "$tmpfile" 2>/dev/null || echo 0)

  # Build semicolon-separated "idx:name" lookup for awk
  local name_lines=""
  for i in $(seq 0 $((np - 1))); do
    local n
    n=$(sed -n "/^\[player${i}\]/,/^\[/p" "$tmpfile" | head -20 | grep '^name=' | head -1 | sed 's/name="//' | sed 's/"//')
    [ -n "$name_lines" ] && name_lines="${name_lines};"
    name_lines="${name_lines}${i}:${n}"
  done

  # Pipeline: extract combat events → pair by timestamp → map indices to names
  local pairs
  pairs=$(sed -n '/^\[event_cache\]/,/^\[/p' "$tmpfile" | \
    grep -E '"E_UNIT_(WIN|LOST)_(ATT|DEF)"' | \
    awk -F',' '{
      ts=$3; gsub(/"/, "", $8)
      for (i=1; i<=length($8); i++)
        if (substr($8,i,1)=="1") { print ts, i-1; break }
    }' | \
    awk -v names="$name_lines" '
    BEGIN {
      n=split(names, arr, ";")
      for (k=1; k<=n; k++) {
        split(arr[k], kv, ":")
        if (kv[1] != "") namemap[kv[1]] = kv[2]
      }
    }
    {
      if ($1==prev_ts && $2!=prev_p) {
        a=($2<prev_p)?$2:prev_p; b=($2<prev_p)?prev_p:$2
        n1=namemap[a]; n2=namemap[b]
        if (n1!="" && n2!="") {
          if (n1>n2) { tmp=n1; n1=n2; n2=tmp }
          pairs[n1 "|" n2]=1
        }
      }
      prev_ts=$1; prev_p=$2
    }
    END { for (p in pairs) print p }' | sort -u)

  if [ -z "$pairs" ]; then
    echo "[]"
  else
    echo "$pairs" | jq -R 'split("|")' | jq -s '.'
  fi
}

# Build diplomacy history from all saves
build_diplomacy() {
  local history="[]"
  local prev_states="{}"
  local all_combat="[]"

  while read -r turn_num save_path; do
    [ -z "$save_path" ] && continue
    [ ! -f "$save_path" ] && continue
    local tmp
    tmp=$(decompress_save "$save_path") || continue
    local entry
    entry=$(extract_diplomacy "$tmp")
    # Extract combat pairs before removing tmp
    local turn_combat
    turn_combat=$(extract_combat_pairs "$tmp")
    if [ "$(echo "$turn_combat" | jq 'length')" -gt 0 ]; then
      all_combat=$(echo "$all_combat" | jq --argjson p "$turn_combat" '. + $p | unique')
    fi
    rm -f "$tmp"

    local turn_year turn_rels
    turn_year=$(echo "$entry" | jq -r '.year')
    turn_rels=$(echo "$entry" | jq -c '.relationships')

    # Detect changes from previous turn
    local changes="[]"
    # Build current state map (key = sorted player pair)
    local current_states="{}"
    for rel in $(echo "$turn_rels" | jq -c '.[]'); do
      local key status
      key=$(echo "$rel" | jq -r '.players | sort | join("|")')
      status=$(echo "$rel" | jq -r '.status')
      current_states=$(echo "$current_states" | jq --arg k "$key" --arg s "$status" '. + {($k): $s}')
    done

    # Find new or changed relationships
    for key in $(echo "$current_states" | jq -r 'keys[]'); do
      local cur_status prev_status
      cur_status=$(echo "$current_states" | jq -r --arg k "$key" '.[$k]')
      prev_status=$(echo "$prev_states" | jq -r --arg k "$key" '.[$k] // "Never met"')
      if [ "$cur_status" != "$prev_status" ]; then
        local p1 p2
        p1=$(echo "$key" | cut -d'|' -f1)
        p2=$(echo "$key" | cut -d'|' -f2)
        changes=$(echo "$changes" | jq \
          --argjson turn "$turn_num" \
          --argjson year "$(echo "$entry" | jq '.year')" \
          --arg p1 "$p1" --arg p2 "$p2" \
          --arg from "$prev_status" --arg to "$cur_status" \
          '. + [{turn: $turn, year: $year, players: [$p1, $p2], from: $from, to: $to}]')
      fi
    done

    # Find relationships that ended (were in prev but not current)
    for key in $(echo "$prev_states" | jq -r 'keys[]'); do
      local in_current
      in_current=$(echo "$current_states" | jq -r --arg k "$key" '.[$k] // "gone"')
      if [ "$in_current" = "gone" ]; then
        local prev_s p1 p2
        prev_s=$(echo "$prev_states" | jq -r --arg k "$key" '.[$k]')
        p1=$(echo "$key" | cut -d'|' -f1)
        p2=$(echo "$key" | cut -d'|' -f2)
        changes=$(echo "$changes" | jq \
          --argjson turn "$turn_num" \
          --argjson year "$(echo "$entry" | jq '.year')" \
          --arg p1 "$p1" --arg p2 "$p2" \
          --arg from "$prev_s" --arg to "Never met" \
          '. + [{turn: $turn, year: $year, players: [$p1, $p2], from: $from, to: $to}]')
      fi
    done

    if [ "$(echo "$changes" | jq 'length')" -gt 0 ]; then
      history=$(echo "$history" | jq --argjson c "$changes" '. + $c')
    fi

    prev_states="$current_states"
  done <<< "$SAVE_FILES"

  # Get current relationships from the latest entry
  local latest_tmp latest_rels
  latest_tmp=$(echo "$SAVE_FILES" | tail -1 | awk '{print $2}')
  if [ -n "$latest_tmp" ] && [ -f "$latest_tmp" ]; then
    local dtmp
    dtmp=$(decompress_save "$latest_tmp") || true
    if [ -n "${dtmp:-}" ] && [ -s "$dtmp" ]; then
      latest_rels=$(extract_diplomacy "$dtmp" | jq '.relationships')
      # Also get combat pairs from latest save
      local latest_combat
      latest_combat=$(extract_combat_pairs "$dtmp")
      if [ "$(echo "$latest_combat" | jq 'length')" -gt 0 ]; then
        all_combat=$(echo "$all_combat" | jq --argjson p "$latest_combat" '. + $p | unique')
      fi
      rm -f "$dtmp"
    else
      latest_rels="[]"
    fi
  else
    latest_rels="[]"
  fi

  # Upgrade Contact → War for pairs that have had actual combat
  if [ "$(echo "$all_combat" | jq 'length')" -gt 0 ]; then
    latest_rels=$(echo "$latest_rels" | jq --argjson cp "$all_combat" '
      [.[] | if .status == "Contact" then
        (.players | sort) as $sp |
        if any($cp[]; sort == $sp) then .status = "War" else . end
      else . end]')
  fi

  # Include the latest turn number for incremental rebuild checks
  local latest_turn
  latest_turn=$(echo "$SAVE_FILES" | tail -1 | awk '{print $1}')
  jq -n \
    --argjson turn "${latest_turn:-0}" \
    --argjson current "$latest_rels" \
    --argjson events "$history" \
    --argjson combat_pairs "$all_combat" \
    '{turn: $turn, current: $current, events: $events, combat_pairs: $combat_pairs}'
}

# Only rebuild diplomacy when a new turn exists or the file is missing/corrupt
NEED_DIPLO_REBUILD=false
if [ ! -f "$DIPLOMACY_FILE" ] || ! jq . "$DIPLOMACY_FILE" >/dev/null 2>&1; then
  NEED_DIPLO_REBUILD=true
else
  DIPLO_LAST_TURN=$(jq '.turn // 0' "$DIPLOMACY_FILE" 2>/dev/null || echo 0)
  if [ "${TURN:-0}" -gt "$DIPLO_LAST_TURN" ] 2>/dev/null; then
    NEED_DIPLO_REBUILD=true
  fi
fi

if [ "$NEED_DIPLO_REBUILD" = "true" ]; then
  echo "[status-json] Building diplomacy data..."
  DIPLOMACY_JSON=$(build_diplomacy)
  echo "$DIPLOMACY_JSON" > "$DIPLOMACY_FILE.tmp"
  mv "$DIPLOMACY_FILE.tmp" "$DIPLOMACY_FILE"
  echo "[status-json] Diplomacy: $(echo "$DIPLOMACY_JSON" | jq '.current | length') active relationships, $(echo "$DIPLOMACY_JSON" | jq '.events | length') events"
else
  # Just update current relationships from the latest save (fast path)
  if [ -n "${LATEST_TMPFILE:-}" ] && [ -s "$LATEST_TMPFILE" ]; then
    CURRENT_RELS=$(extract_diplomacy "$LATEST_TMPFILE" | jq '.relationships')
    # Check for new combat events and merge with existing
    NEW_COMBAT=$(extract_combat_pairs "$LATEST_TMPFILE")
    EXISTING_COMBAT=$(jq '.combat_pairs // []' "$DIPLOMACY_FILE")
    MERGED_COMBAT=$(echo "$EXISTING_COMBAT" | jq --argjson n "$NEW_COMBAT" '. + $n | unique')
    # Upgrade Contact → War for combat pairs
    if [ "$(echo "$MERGED_COMBAT" | jq 'length')" -gt 0 ]; then
      CURRENT_RELS=$(echo "$CURRENT_RELS" | jq --argjson cp "$MERGED_COMBAT" '
        [.[] | if .status == "Contact" then
          (.players | sort) as $sp |
          if any($cp[]; sort == $sp) then .status = "War" else . end
        else . end]')
    fi
    jq --argjson rels "$CURRENT_RELS" --argjson cp "$MERGED_COMBAT" \
      '.current = $rels | .combat_pairs = $cp' "$DIPLOMACY_FILE" > "$DIPLOMACY_FILE.tmp"
    mv "$DIPLOMACY_FILE.tmp" "$DIPLOMACY_FILE"
  fi
fi

# Symlink diplomacy.json into webroot for HTTP serving
ln -sf "$DIPLOMACY_FILE" "$WEBROOT/diplomacy.json"

# ============================================================================
# Track player status: phase_done, connection, connected_this_turn
# ============================================================================
# CRITICAL: unset before declare -A (bash 5 does not clear existing arrays)
unset PHASE_DONE_MAP
declare -A PHASE_DONE_MAP
unset CONNECTED_MAP
declare -A CONNECTED_MAP
unset CONNECTED_THIS_TURN_MAP
declare -A CONNECTED_THIS_TURN_MAP

if [ "$TURN" != "0" ] && [ "$NO_LIVE" = "false" ] && [ -p /tmp/server-input ]; then
  # Track who has connected this turn (from log — only lines after the current turn started)
  if [ -f "$LOGFILE" ]; then
    TURN_START_LINE=$(grep -n "Game saved as.*lt-game-" "$LOGFILE" 2>/dev/null | tail -1 | cut -d: -f1)
    [ -z "$TURN_START_LINE" ] && TURN_START_LINE=0
    while IFS= read -r line; do
      conn_name=$(echo "$line" | sed 's/.*[0-9]: \(.*\) has connected from.*/\1/')
      if [ -n "$conn_name" ]; then
        conn_lower=$(echo "$conn_name" | tr 'A-Z' 'a-z')
        CONNECTED_THIS_TURN_MAP["$conn_lower"]="true"
      fi
    done < <(tail -n +"$((TURN_START_LINE + 1))" "$LOGFILE" 2>/dev/null | grep "has connected from")
  fi

  # Force a live save to capture current phase_done state
  PRE_SAVE_LINES=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
  rm -f /tmp/status-snapshot.sav*
  echo "save /tmp/status-snapshot" > /tmp/server-input 2>/dev/null
  # Wait for server to confirm save is complete (check log for "Game saved" message)
  SNAP_WAIT=0
  while [ $SNAP_WAIT -lt 10 ]; do
    sleep 1
    SNAP_WAIT=$((SNAP_WAIT + 1))
    tail -n +"$((PRE_SAVE_LINES + 1))" "$LOGFILE" 2>/dev/null | grep -q "Game saved as" && break
  done

  SNAP_FILE=$(ls -1t /tmp/status-snapshot.sav* 2>/dev/null | head -1)
  if [ -n "$SNAP_FILE" ] && [ -f "$SNAP_FILE" ]; then
    SNAP_TMP=$(decompress_save "$SNAP_FILE") || true
    if [ -n "${SNAP_TMP:-}" ] && [ -s "$SNAP_TMP" ]; then
      SNAP_NPLAYERS=$(grep -c '^\[player[0-9]' "$SNAP_TMP" 2>/dev/null || echo 0)
      for i in $(seq 0 $((SNAP_NPLAYERS - 1))); do
        SNAP_SEC=$(sed -n "/^\[player${i}\]/,/^\[/p" "$SNAP_TMP" | head -150)
        snap_name=$(echo "$SNAP_SEC" | grep '^name=' | head -1 | sed 's/name="//' | sed 's/"//')
        snap_done=$(echo "$SNAP_SEC" | grep '^phase_done=' | head -1 | sed 's/phase_done=//')
        snap_lower=$(echo "$snap_name" | tr 'A-Z' 'a-z')
        [ "$snap_done" = "TRUE" ] && PHASE_DONE_MAP["$snap_lower"]="true"
      done
      # Use the live snapshot for rankings instead of stale turn-start save
      rm -f "$LATEST_TMPFILE"
      LATEST_TMPFILE="$SNAP_TMP"
    fi
    rm -f /tmp/status-snapshot.sav*
  fi

  # Use 'list' command for connection status (who's online right now)
  PRE_LIST_LINES=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
  echo "list" > /tmp/server-input 2>/dev/null
  sleep 2
  LIST_OUTPUT=$(tail -n +$((PRE_LIST_LINES + 1)) "$LOGFILE" 2>/dev/null)

  CURRENT_PNAME=""
  while IFS= read -r line; do
    if echo "$line" | grep -qE '^[[:space:]]*[A-Za-z].*\[#[0-9a-f]+\]'; then
      pname=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/ \[#.*//')
      case "$pname" in *Orca*|*arbarian*) CURRENT_PNAME=""; continue ;; esac
      CURRENT_PNAME="$pname"
    elif [ -n "$CURRENT_PNAME" ]; then
      if echo "$line" | grep -q "connection"; then
        p_lower=$(echo "$CURRENT_PNAME" | tr 'A-Z' 'a-z')
        CONNECTED_MAP["$p_lower"]="true"
      fi
      CURRENT_PNAME=""
    else
      CURRENT_PNAME=""
    fi
  done <<< "$LIST_OUTPUT"

elif [ "$TURN" != "0" ] && [ "$NO_LIVE" = "true" ]; then
  # In --no-live mode, read phase_done from the latest save file
  if [ -n "$LATEST_TMPFILE" ] && [ -s "$LATEST_TMPFILE" ]; then
    NP=$(grep -c '^\[player[0-9]' "$LATEST_TMPFILE" 2>/dev/null || echo 0)
    for i in $(seq 0 $((NP - 1))); do
      SEC=$(sed -n "/^\[player${i}\]/,/^\[/p" "$LATEST_TMPFILE" | head -150)
      sn=$(echo "$SEC" | grep '^name=' | head -1 | sed 's/name="//' | sed 's/"//')
      sd=$(echo "$SEC" | grep '^phase_done=' | head -1 | sed 's/phase_done=//')
      sl=$(echo "$sn" | tr 'A-Z' 'a-z')
      [ "$sd" = "TRUE" ] && PHASE_DONE_MAP["$sl"]="true"
    done
  fi

  # Parse connected_this_turn from log
  if [ -f "$LOGFILE" ]; then
    TURN_START_LINE=$(grep -n "Game saved as.*lt-game-" "$LOGFILE" 2>/dev/null | tail -1 | cut -d: -f1)
    [ -z "$TURN_START_LINE" ] && TURN_START_LINE=0
    while IFS= read -r line; do
      conn_name=$(echo "$line" | sed 's/.*[0-9]: \(.*\) has connected from.*/\1/')
      if [ -n "$conn_name" ]; then
        conn_lower=$(echo "$conn_name" | tr 'A-Z' 'a-z')
        CONNECTED_THIS_TURN_MAP["$conn_lower"]="true"
      fi
    done < <(tail -n +"$((TURN_START_LINE + 1))" "$LOGFILE" 2>/dev/null | grep "has connected from")
  fi
fi

# ============================================================================
# Build rankings from latest save
# ============================================================================
PLAYERS_JSON="[]"
DONE_COUNT=0
ONLINE_COUNT=0
LOGGEDIN_COUNT=0
TOTAL_RANKED=0

if [ -n "${LATEST_TMPFILE:-}" ] && [ -s "$LATEST_TMPFILE" ]; then
  NUM_PLAYERS=$(grep -c '^\[player[0-9]' "$LATEST_TMPFILE" 2>/dev/null || echo 0)
  declare -a P_NAMES P_NATIONS P_GOLD P_GOV P_NCITIES P_NUNITS P_SCORES P_IS_ALIVE P_IDLE_TURNS

  for i in $(seq 0 $((NUM_PLAYERS - 1))); do
    SECTION=$(sed -n "/^\[player${i}\]/,/^\[/p" "$LATEST_TMPFILE" | head -150)
    P_NAMES[$i]=$(echo "$SECTION" | grep '^name=' | head -1 | sed 's/name="//' | sed 's/"//')
    P_NATIONS[$i]=$(echo "$SECTION" | grep '^nation=' | head -1 | sed 's/nation="//' | sed 's/"//')
    P_GOLD[$i]=$(echo "$SECTION" | grep '^gold=' | head -1 | sed 's/gold=//')
    P_NCITIES[$i]=$(echo "$SECTION" | grep '^ncities=' | head -1 | sed 's/ncities=//')
    P_NUNITS[$i]=$(echo "$SECTION" | grep '^nunits=' | head -1 | sed 's/nunits=//')
    P_GOV[$i]=$(echo "$SECTION" | grep '^government_name=' | head -1 | sed 's/government_name="//' | sed 's/"//')
    P_IS_ALIVE[$i]=$(echo "$SECTION" | grep '^is_alive=' | head -1 | sed 's/is_alive=//')
    P_IDLE_TURNS[$i]=$(echo "$SECTION" | grep '^idle_turns=' | head -1 | sed 's/idle_turns=//')

    SCORE_SECTION=$(sed -n "/^\[score${i}\]/,/^\[/p" "$LATEST_TMPFILE" | head -30)
    P_SCORES[$i]=$(echo "$SCORE_SECTION" | grep '^total=' | head -1 | sed 's/total=//')
    [ -z "${P_SCORES[$i]}" ] && P_SCORES[$i]="0"
  done

  # Sort by score descending, filter out barbarians/animals
  SORTED=""
  for i in $(seq 0 $((NUM_PLAYERS - 1))); do
    name="${P_NAMES[$i]}"
    nation="${P_NATIONS[$i]}"
    case "$name" in *arbarian*|Lion|Pirates) continue ;; esac
    case "$nation" in *animal*) continue ;; esac
    SORTED="${SORTED}${P_SCORES[$i]:-0}|${i}\n"
  done
  SORTED_INDICES=$(echo -e "$SORTED" | sort -t'|' -k1 -rn | grep -v '^$')

  # Load last-seen data
  LAST_SEEN_FILE="$SAVE_DIR/last_seen.txt"
  unset LAST_SEEN_MAP
  declare -A LAST_SEEN_MAP
  if [ -f "$LAST_SEEN_FILE" ]; then
    while IFS=: read -r ls_name ls_epoch; do
      [ -n "$ls_name" ] && LAST_SEEN_MAP["$ls_name"]="$ls_epoch"
    done < "$LAST_SEEN_FILE"
  fi

  # Build players JSON array (sorted by score desc)
  RANK=1
  PLAYER_JSON_ENTRIES=""

  while IFS='|' read -r score idx; do
    [ -z "$idx" ] && continue
    name="${P_NAMES[$idx]}"
    nation="${P_NATIONS[$idx]}"
    nation_cap="${nation^}"
    gold="${P_GOLD[$idx]:-0}"
    gov="${P_GOV[$idx]:-Despotism}"
    ncities="${P_NCITIES[$idx]:-0}"
    nunits="${P_NUNITS[$idx]:-0}"
    is_alive_raw="${P_IS_ALIVE[$idx]}"
    TOTAL_RANKED=$((TOTAL_RANKED + 1))

    # Convert to JSON booleans
    is_alive_json="true"
    [ "$is_alive_raw" = "FALSE" ] && is_alive_json="false"

    p_lower=$(echo "$name" | tr 'A-Z' 'a-z')
    is_done="${PHASE_DONE_MAP[$p_lower]:-}"
    is_connected="${CONNECTED_MAP[$p_lower]:-}"
    connected_this_turn="${CONNECTED_THIS_TURN_MAP[$p_lower]:-}"

    phase_done_json="false"
    is_connected_json="false"
    connected_this_turn_json="false"

    if [ "$is_done" = "true" ]; then
      phase_done_json="true"
      DONE_COUNT=$((DONE_COUNT + 1))
      LOGGEDIN_COUNT=$((LOGGEDIN_COUNT + 1))
      [ "$is_connected" = "true" ] && { is_connected_json="true"; ONLINE_COUNT=$((ONLINE_COUNT + 1)); }
    elif [ "$is_connected" = "true" ]; then
      is_connected_json="true"
      ONLINE_COUNT=$((ONLINE_COUNT + 1))
      LOGGEDIN_COUNT=$((LOGGEDIN_COUNT + 1))
    elif [ "$connected_this_turn" = "true" ]; then
      connected_this_turn_json="true"
      LOGGEDIN_COUNT=$((LOGGEDIN_COUNT + 1))
    fi

    # Last seen epoch (null if not found)
    ls_epoch="${LAST_SEEN_MAP[$p_lower]:-}"
    if [ -n "$ls_epoch" ]; then
      last_seen_json="$ls_epoch"
    else
      last_seen_json="null"
    fi

    # Idle turn streak from save file (don't count current in-progress turn)
    idle_streak="${P_IDLE_TURNS[$idx]:-0}"
    [ -z "$idle_streak" ] && idle_streak=0
    # If they've connected this turn, they're not idle regardless of save value
    if [ "$phase_done_json" = "true" ] || [ "$is_connected_json" = "true" ] || [ "$connected_this_turn_json" = "true" ]; then
      idle_streak=0
    fi

    # Attendance data from attendance.json
    att_missed=$(echo "${ATTENDANCE_JSON:-{\}}" | jq --arg n "$name" '.[$n].missed_turns // 0')
    att_total=$(echo "${ATTENDANCE_JSON:-{\}}" | jq --arg n "$name" '.[$n].total_turns // 0')

    PLAYER_OBJ=$(jq -n \
      --arg name "$name" \
      --arg nation "$nation_cap" \
      --argjson score "${score:-0}" \
      --argjson cities "${ncities}" \
      --argjson units "${nunits}" \
      --argjson gold "${gold}" \
      --arg government "$gov" \
      --argjson is_alive "$is_alive_json" \
      --argjson rank "$RANK" \
      --argjson phase_done "$phase_done_json" \
      --argjson is_connected "$is_connected_json" \
      --argjson connected_this_turn "$connected_this_turn_json" \
      --argjson last_seen_epoch "$last_seen_json" \
      --argjson idle_turn_streak "$idle_streak" \
      --argjson missed_turns "$att_missed" \
      --argjson total_turns "$att_total" \
      '{
        name: $name,
        nation: $nation,
        score: $score,
        cities: $cities,
        units: $units,
        gold: $gold,
        government: $government,
        is_alive: $is_alive,
        rank: $rank,
        phase_done: $phase_done,
        is_connected: $is_connected,
        connected_this_turn: $connected_this_turn,
        last_seen_epoch: $last_seen_epoch,
        idle_turn_streak: $idle_turn_streak,
        missed_turns: $missed_turns,
        total_turns: $total_turns
      }')

    if [ -n "$PLAYER_JSON_ENTRIES" ]; then
      PLAYER_JSON_ENTRIES="${PLAYER_JSON_ENTRIES}
${PLAYER_OBJ}"
    else
      PLAYER_JSON_ENTRIES="${PLAYER_OBJ}"
    fi

    RANK=$((RANK + 1))
  done <<< "$SORTED_INDICES"

  if [ -n "$PLAYER_JSON_ENTRIES" ]; then
    PLAYERS_JSON=$(echo "$PLAYER_JSON_ENTRIES" | jq -s '.')
  fi

  rm -f "$LATEST_TMPFILE"
fi

# ============================================================================
# Calculate deadline / timeout
# ============================================================================
TURN_TIMEOUT=82800

# Check server log for the most recent "set timeout"
if [ -f "$LOGFILE" ]; then
  LIVE_TIMEOUT=$(grep "'timeout' has been set to" "$LOGFILE" 2>/dev/null | tail -1 | sed "s/.*set to \([0-9]*\).*/\1/")
  if [ -n "${LIVE_TIMEOUT:-}" ] && [ "$LIVE_TIMEOUT" -gt 0 ] 2>/dev/null; then
    TURN_TIMEOUT="$LIVE_TIMEOUT"
  fi
fi

# Fallback: read timeout from save file settings
if [ "$TURN_TIMEOUT" = "82800" ] && [ -n "${LATEST_SAVE_FILE:-}" ] && [ -f "$LATEST_SAVE_FILE" ]; then
  TIMEOUT_VAL=$(zcat "$LATEST_SAVE_FILE" 2>/dev/null | grep '^"timeout",' | head -1 | cut -d',' -f2)
  if [ -n "${TIMEOUT_VAL:-}" ] && [ "$TIMEOUT_VAL" -gt 0 ] 2>/dev/null; then
    TURN_TIMEOUT="$TIMEOUT_VAL"
  fi
fi

# Turn start epoch
TURN_START_EPOCH=$(cat "$SAVE_DIR/turn_start_epoch" 2>/dev/null || echo 0)

if [ "$TURN_START_EPOCH" -gt 0 ] 2>/dev/null; then
  DEADLINE_EPOCH=$((TURN_START_EPOCH + TURN_TIMEOUT))
elif [ -n "${LATEST_SAVE_FILE:-}" ] && [ -f "$LATEST_SAVE_FILE" ]; then
  DEADLINE_EPOCH=$(($(stat -c %Y "$LATEST_SAVE_FILE" 2>/dev/null || stat -f %m "$LATEST_SAVE_FILE" 2>/dev/null || echo 0) + TURN_TIMEOUT))
else
  DEADLINE_EPOCH=$(($(date +%s) + TURN_TIMEOUT))
fi

# Save file mtime
SAVE_MTIME=0
if [ -n "${LATEST_SAVE_FILE:-}" ] && [ -f "$LATEST_SAVE_FILE" ]; then
  SAVE_MTIME=$(stat -c %Y "$LATEST_SAVE_FILE" 2>/dev/null || stat -f %m "$LATEST_SAVE_FILE" 2>/dev/null || echo 0)
fi

# ============================================================================
# Assemble the final JSON (no history — that's in history.json now)
# ============================================================================
NOW_EPOCH=$(date +%s)
GENERATED_AT=$(date -u '+%Y-%m-%d %H:%M UTC')

OUTPUT_JSON=$(jq -n \
  --arg generated_at "$GENERATED_AT" \
  --argjson generated_epoch "$NOW_EPOCH" \
  --arg server_host "$SERVER_HOST" \
  --argjson server_port "$SERVER_PORT" \
  --arg join_form_url "$JOIN_FORM" \
  --arg game_version "$GAME_VERSION" \
  --arg ruleset "$RULESET" \
  --argjson turn "${TURN}" \
  --argjson year "${YEAR}" \
  --arg year_display "$YEAR_DISPLAY" \
  --arg server_status "$SERVER_STATUS" \
  --argjson registered_player_count "${PLAYER_COUNT}" \
  --argjson deadline_epoch "${DEADLINE_EPOCH}" \
  --argjson turn_timeout "${TURN_TIMEOUT}" \
  --argjson save_mtime "${SAVE_MTIME}" \
  --argjson turn_start_epoch "${TURN_START_EPOCH}" \
  --argjson players "$PLAYERS_JSON" \
  --argjson done_count "$DONE_COUNT" \
  --argjson online_count "$ONLINE_COUNT" \
  --argjson logged_in_count "$LOGGEDIN_COUNT" \
  --argjson total_players "$TOTAL_RANKED" \
  '{
    meta: {
      generated_at: $generated_at,
      generated_epoch: $generated_epoch,
      server_host: $server_host,
      server_port: $server_port,
      join_form_url: $join_form_url,
      game_version: $game_version,
      ruleset: $ruleset
    },
    game: {
      turn: $turn,
      year: $year,
      year_display: $year_display,
      server_status: $server_status,
      registered_player_count: $registered_player_count,
      deadline_epoch: $deadline_epoch,
      turn_timeout: $turn_timeout,
      save_mtime: $save_mtime,
      turn_start_epoch: $turn_start_epoch
    },
    players: $players,
    activity: {
      done_count: $done_count,
      online_count: $online_count,
      logged_in_count: $logged_in_count,
      total_players: $total_players
    }
  }')

# ============================================================================
# Write output files
# ============================================================================
mkdir -p "$WEBROOT"

# Write status.json to persistent volume and symlink into webroot
echo "$OUTPUT_JSON" > "$SAVE_DIR/status.json.tmp"
mv "$SAVE_DIR/status.json.tmp" "$SAVE_DIR/status.json"
ln -sf "$SAVE_DIR/status.json" "$WEBROOT/status.json"

echo "[status-json] Generated status.json (turn ${TURN}, ${YEAR_DISPLAY})"
