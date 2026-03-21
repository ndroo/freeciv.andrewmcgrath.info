#!/bin/bash
# =============================================================================
# Generates a "Gazette" newspaper article for a given turn using OpenAI.
#
# Reads aggregate game data from status.json, history.json, and diplomacy.json.
# Produces a fun, unreliable wartime newspaper entry. Occasionally injects
# misinformation which gets retracted in a later issue.
#
# Usage:
#   ./generate_gazette.sh <turn> [year]
#   ./generate_gazette.sh --rebuild   # rebuild all past gazette entries
#
# Requires: curl, jq
# Env: OPENAI_API_KEY (or reads from /data/saves/openai_api_key)
# =============================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAVE_DIR="${SAVE_DIR:-/data/saves}"
WEBROOT="${WEBROOT:-/opt/freeciv/www}"
GAZETTE_FILE="$SAVE_DIR/gazette.json"
HISTORY_FILE="$SAVE_DIR/history.json"
DIPLOMACY_FILE="$SAVE_DIR/diplomacy.json"

# API key: env var > .env file in script dir > file in save dir
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
if [ -z "$OPENAI_API_KEY" ] && [ -f "$SCRIPT_DIR/.env" ]; then
  OPENAI_API_KEY=$(grep '^OPENAI_API_KEY=' "$SCRIPT_DIR/.env" | head -1 | sed 's/^OPENAI_API_KEY=//' | tr -d '[:space:]"'"'")
fi
if [ -z "$OPENAI_API_KEY" ] && [ -f "$SAVE_DIR/openai_api_key" ]; then
  OPENAI_API_KEY=$(cat "$SAVE_DIR/openai_api_key" | tr -d '[:space:]')
fi
if [ -z "$OPENAI_API_KEY" ]; then
  echo "[gazette] No OpenAI API key found, skipping"
  exit 0
fi

# Parse args
REBUILD=false
TURN=""
YEAR=""
for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=true ;;
    *) if [ -z "$TURN" ]; then TURN="$arg"; elif [ -z "$YEAR" ]; then YEAR="$arg"; fi ;;
  esac
done

# Load or init gazette
if [ -f "$GAZETTE_FILE" ] && jq . "$GAZETTE_FILE" >/dev/null 2>&1; then
  GAZETTE_JSON=$(cat "$GAZETTE_FILE")
else
  GAZETTE_JSON="[]"
fi

# ---------------------------------------------------------------------------
# Build the context for a single turn's gazette entry
# ---------------------------------------------------------------------------
build_turn_context() {
  local target_turn="$1"
  local history diplomacy

  [ ! -f "$HISTORY_FILE" ] && { echo "{}"; return; }
  history=$(cat "$HISTORY_FILE")
  diplomacy=$(cat "$DIPLOMACY_FILE" 2>/dev/null || echo '{"current":[],"events":[]}')

  # Get current and previous turn data from history
  local current_entry prev_entry
  current_entry=$(echo "$history" | jq --argjson t "$target_turn" '[.[] | select(.turn == $t)] | .[0] // empty')
  prev_entry=$(echo "$history" | jq --argjson t "$((target_turn - 1))" '[.[] | select(.turn == $t)] | .[0] // empty')

  [ -z "$current_entry" ] && { echo "{}"; return; }

  # Build aggregate stats (no per-player breakdown to avoid leaking strategy)
  local context
  context=$(jq -n \
    --argjson curr "$current_entry" \
    --argjson prev "${prev_entry:-null}" \
    --argjson dipl_events "$(echo "$diplomacy" | jq --argjson t "$target_turn" '[.events[] | select(.turn == $t)]')" \
    --argjson all_history "$history" \
    '{
      turn: $curr.turn,
      year: $curr.year,
      year_display: (if $curr.year < 0 then "\(-$curr.year) BC" else "\($curr.year) AD" end),
      player_count: ($curr.players | keys | length),
      players: [$curr.players | to_entries[] | .key],

      totals: {
        total_cities: [$curr.players | to_entries[].value.cities] | add,
        total_units: [$curr.players | to_entries[].value.units] | add,
        total_population_proxy: [$curr.players | to_entries[].value.score] | add,
        total_techs: [$curr.players | to_entries[].value.techs // 0] | add,
        avg_gold: ([$curr.players | to_entries[].value.gold] | add / ([$curr.players | to_entries[].value.gold] | length)),
        govs_in_use: [$curr.players | to_entries[].value.government] | unique
      },

      deltas: (if $prev then (
        ([$curr.players | to_entries[].value.cities] | add) as $cc |
        ([$prev.players | to_entries[].value.cities] | add) as $pc |
        ([$curr.players | to_entries[].value.units] | add) as $cu |
        ([$prev.players | to_entries[].value.units] | add) as $pu |
        ([$curr.players | to_entries[].value.score] | add) as $cs |
        ([$prev.players | to_entries[].value.score] | add) as $ps |
        {
          cities_change: ($cc - $pc),
          units_change: ($cu - $pu),
          score_change: ($cs - $ps),
          new_players: [$curr.players | keys[] | select(. as $k | $prev.players | has($k) | not)]
        }
      ) else null end),

      diplomacy_events: [
        $dipl_events[] | {
          players: .players,
          type: (if .to == "Contact" then "first_contact"
                 elif .to == "War" then "war_declared"
                 elif .to == "Peace" then "peace_signed"
                 elif .to == "Alliance" then "alliance_formed"
                 elif .to == "Ceasefire" then "ceasefire"
                 elif .to == "Armistice" then "armistice"
                 else .from + " -> " + .to end)
        }
      ],

      score_leaders: [$curr.players | to_entries | sort_by(-.value.score)[:3] | .[].key],
      city_leaders: [$curr.players | to_entries | sort_by(-.value.cities)[:3] | .[].key],
      military_leaders: [$curr.players | to_entries | sort_by(-.value.units)[:3] | .[].key]
    }')

  echo "$context"
}

# ---------------------------------------------------------------------------
# Call OpenAI to generate a gazette entry
# ---------------------------------------------------------------------------
generate_entry() {
  local context="$1"
  local turn year_display
  turn=$(echo "$context" | jq -r '.turn')
  year_display=$(echo "$context" | jq -r '.year_display')

  local system_prompt
  system_prompt=$(cat <<'SYSPROMPT'
You are the editor of "The Civ Chronicle", a wartime newspaper covering a Freeciv multiplayer game.

Your writing style should evolve with the era:
- Ancient era (4000 BC - 1000 BC): Write like ancient chronicles and proclamations. Dramatic, mythic tone. "The gods smile upon..." / "Let it be known..." — but keep it readable for a modern audience.
- Classical era (1000 BC - 500 AD): Roman/Greek historian style. Formal, authoritative, slightly pompous. Think Herodotus or Livy writing a tabloid.
- Medieval era (500 AD - 1400 AD): Town crier / medieval chronicle style. "Hear ye!" / "It is whispered in the courts..."
- Renaissance/Colonial (1400 - 1800): Broadsheet pamphlet style. Flowery but pointed, like 18th century newspapers.
- Industrial/Modern (1800+): Modern newspaper style. Punchy headlines, wire-service tone, with editorial flair.

Always keep it entertaining and understandable to a modern reader — the era flavoring is seasoning, not a barrier.

Rules:
- Write 3-5 short paragraphs as a newspaper article
- Use the aggregate data provided (total cities, units, scores, diplomacy events)
- DO NOT reveal specific player strategies, unit compositions, or per-player gold amounts
- DO NOT quote exact numbers for individual players. Keep individual details vague ("a growing empire", "one of the larger armies") so as not to give away strategic info
- You MAY name score leaders, city leaders, and military leaders — but be vague about the gap between them
- You MAY include rumors, gossip, and speculation — frame them clearly as "rumors suggest", "sources whisper", "unconfirmed reports indicate". These add flavor. They should be plausible but not confirmable from the data.
- Diplomacy events (first contact, peace, war, alliances) are public knowledge and can be reported directly
- Aggregate totals (total cities in the world, total units, general tech progress) are fine to share
- Keep it entertaining and dramatic — exaggerate for effect

Return your response as JSON with this exact structure:
{"headline": "...", "article": "..."}

The article field should use simple HTML (<p>, <strong>, <em>) for formatting.
SYSPROMPT
)

  local user_prompt="Write the gazette for Turn ${turn} (${year_display}).

Game context:
${context}"

  local request_body
  request_body=$(jq -n \
    --arg system "$system_prompt" \
    --arg user "$user_prompt" \
    '{
      model: "gpt-5.2",
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $user}
      ],
      temperature: 0.9,
      max_completion_tokens: 1000,
      response_format: {type: "json_object"}
    }')

  local response
  response=$(curl -s --max-time 30 \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$request_body" \
    "https://api.openai.com/v1/chat/completions")

  local content
  content=$(echo "$response" | jq -r '.choices[0].message.content // empty')

  if [ -z "$content" ]; then
    echo "[gazette] OpenAI call failed for turn $turn" >&2
    echo "$response" | jq . >&2 2>/dev/null || echo "$response" >&2
    return 1
  fi

  # Validate it's JSON with expected fields
  if ! echo "$content" | jq -e '.headline and .article' >/dev/null 2>&1; then
    echo "[gazette] Invalid response format for turn $turn" >&2
    return 1
  fi

  echo "$content"
}

# ---------------------------------------------------------------------------
# Process a single turn
# ---------------------------------------------------------------------------
process_turn() {
  local target_turn="$1"

  # Skip if already generated
  local exists
  exists=$(echo "$GAZETTE_JSON" | jq --argjson t "$target_turn" '[.[] | select(.turn == $t)] | length')
  if [ "$exists" -gt 0 ] && [ "$REBUILD" = "false" ]; then
    echo "[gazette] Turn $target_turn already exists, skipping"
    return 0
  fi

  echo "[gazette] Generating gazette for turn $target_turn..."
  local context
  context=$(build_turn_context "$target_turn")
  [ "$context" = "{}" ] && { echo "[gazette] No history data for turn $target_turn"; return 0; }

  local entry
  entry=$(generate_entry "$context") || return 1

  local year
  year=$(echo "$context" | jq -r '.year')
  local year_display
  year_display=$(echo "$context" | jq -r '.year_display')

  # Remove existing entry for this turn if rebuilding
  GAZETTE_JSON=$(echo "$GAZETTE_JSON" | jq --argjson t "$target_turn" '[.[] | select(.turn != $t)]')

  # Add new entry
  GAZETTE_JSON=$(echo "$GAZETTE_JSON" | jq --argjson t "$target_turn" --argjson y "$year" \
    --arg yd "$year_display" --argjson entry "$entry" \
    '. + [{
      turn: $t,
      year: $y,
      year_display: $yd,
      headline: $entry.headline,
      article: $entry.article
    }] | sort_by(.turn)')

  # Save after each entry
  echo "$GAZETTE_JSON" > "$GAZETTE_FILE.tmp"
  mv "$GAZETTE_FILE.tmp" "$GAZETTE_FILE"
  ln -sf "$GAZETTE_FILE" "$WEBROOT/gazette.json"

  echo "[gazette] Generated: $(echo "$entry" | jq -r '.headline')"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "$REBUILD" = "true" ]; then
  echo "[gazette] Rebuilding gazette for all turns..."
  GAZETTE_JSON="[]"
  [ ! -f "$HISTORY_FILE" ] && { echo "[gazette] No history.json found"; exit 0; }
  TURNS=$(jq -r '.[].turn' "$HISTORY_FILE" | sort -n)
  # Skip turn 1 (no previous turn to compare), skip the latest (in progress)
  LAST_TURN=$(echo "$TURNS" | tail -1)
  for t in $TURNS; do
    [ "$t" -le 1 ] 2>/dev/null && continue
    [ "$t" -eq "$LAST_TURN" ] 2>/dev/null && continue
    process_turn "$t"
    sleep 1  # rate limit courtesy
  done
  echo "[gazette] Rebuild complete: $(echo "$GAZETTE_JSON" | jq 'length') entries"
else
  [ -z "$TURN" ] && { echo "Usage: $0 <turn> [year]  or  $0 --rebuild"; exit 1; }
  # Generate for the PREVIOUS turn (current turn just started, previous is complete)
  PREV_TURN=$((TURN - 1))
  [ "$PREV_TURN" -le 1 ] && { echo "[gazette] Too early for gazette (turn $PREV_TURN)"; exit 0; }
  process_turn "$PREV_TURN"
fi

echo "[gazette] Done"
