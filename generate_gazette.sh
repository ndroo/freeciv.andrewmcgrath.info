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

# Provider: anthropic or openai (default: openai)
GAZETTE_PROVIDER="${GAZETTE_PROVIDER:-}"
if [ -z "$GAZETTE_PROVIDER" ] && [ -f "$SCRIPT_DIR/.env" ]; then
  GAZETTE_PROVIDER=$(grep '^GAZETTE_PROVIDER=' "$SCRIPT_DIR/.env" | head -1 | sed 's/^GAZETTE_PROVIDER=//' | tr -d '[:space:]"'"'")
fi
if [ -z "$GAZETTE_PROVIDER" ] && [ -f "$SAVE_DIR/gazette_provider" ]; then
  GAZETTE_PROVIDER=$(cat "$SAVE_DIR/gazette_provider" | tr -d '[:space:]')
fi
GAZETTE_PROVIDER="${GAZETTE_PROVIDER:-openai}"

# API keys: env var > .env file in script dir > file in save dir
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
if [ -z "$OPENAI_API_KEY" ] && [ -f "$SCRIPT_DIR/.env" ]; then
  OPENAI_API_KEY=$(grep '^OPENAI_API_KEY=' "$SCRIPT_DIR/.env" | head -1 | sed 's/^OPENAI_API_KEY=//' | tr -d '[:space:]"'"'")
fi
if [ -z "$OPENAI_API_KEY" ] && [ -f "$SAVE_DIR/openai_api_key" ]; then
  OPENAI_API_KEY=$(cat "$SAVE_DIR/openai_api_key" | tr -d '[:space:]')
fi

ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
if [ -z "$ANTHROPIC_API_KEY" ] && [ -f "$SCRIPT_DIR/.env" ]; then
  ANTHROPIC_API_KEY=$(grep '^ANTHROPIC_API_KEY=' "$SCRIPT_DIR/.env" | head -1 | sed 's/^ANTHROPIC_API_KEY=//' | tr -d '[:space:]"'"'")
fi
if [ -z "$ANTHROPIC_API_KEY" ] && [ -f "$SAVE_DIR/anthropic_api_key" ]; then
  ANTHROPIC_API_KEY=$(cat "$SAVE_DIR/anthropic_api_key" | tr -d '[:space:]')
fi

# Validate we have a key for the chosen provider
if [ "$GAZETTE_PROVIDER" = "anthropic" ] && [ -z "$ANTHROPIC_API_KEY" ]; then
  echo "[gazette] No Anthropic API key found, falling back to openai"
  GAZETTE_PROVIDER="openai"
fi
if [ "$GAZETTE_PROVIDER" = "openai" ] && [ -z "$OPENAI_API_KEY" ]; then
  if [ -n "$ANTHROPIC_API_KEY" ]; then
    echo "[gazette] No OpenAI API key found, falling back to anthropic"
    GAZETTE_PROVIDER="anthropic"
  else
    echo "[gazette] No API key found for any provider, skipping"
    exit 0
  fi
fi
echo "[gazette] Using provider: $GAZETTE_PROVIDER"

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

  # All player correspondence — the gazette AI decides what to include
  # published=0 means not yet used, published=<turn> means used in that edition
  local DB_PATH="${DB_PATH:-/data/saves/freeciv.sqlite}"
  local submissions="[]"
  if [ -f "$DB_PATH" ]; then
    # Unpublished messages (never used in a gazette) + recently published (for context/continuity)
    submissions=$(sqlite3 -json "$DB_PATH" "
      SELECT player_name, role, content, published,
        CASE WHEN published > 0 THEN 'Published in edition ' || published ELSE 'Not yet published' END as pub_status
      FROM editor_messages
      WHERE turn >= $((target_turn - 3)) OR published = 0
      ORDER BY created_at;" 2>/dev/null | jq -c '.' 2>/dev/null || echo "[]")
    [ -z "$submissions" ] && submissions="[]"
  fi

  # Build aggregate stats (no per-player breakdown to avoid leaking strategy)
  # Public information only — per-player details stay private unless inherently visible
  # Pre-filter history to last 5 turns to avoid ARG_MAX overflow on the jq command line
  local recent_history
  recent_history=$(echo "$history" | jq --argjson t "$target_turn" '[.[] | select(.turn > ($t - 5))]')

  # Write data to temp files to avoid ARG_MAX limits on jq command line
  local _tmpdir=$(mktemp -d)
  echo "$submissions" > "$_tmpdir/subs.json"
  echo "$current_entry" > "$_tmpdir/curr.json"
  echo "${prev_entry:-null}" > "$_tmpdir/prev.json"
  echo "$diplomacy" | jq --argjson t "$target_turn" '[.events[] | select(.turn == $t)]' > "$_tmpdir/dipl_events.json"
  echo "$diplomacy" | jq '.current // []' > "$_tmpdir/all_dipl.json"
  echo "$recent_history" > "$_tmpdir/hist.json"

  local context
  context=$(jq -n \
    --slurpfile player_subs "$_tmpdir/subs.json" \
    --slurpfile curr "$_tmpdir/curr.json" \
    --slurpfile prev "$_tmpdir/prev.json" \
    --slurpfile dipl_events "$_tmpdir/dipl_events.json" \
    --slurpfile all_dipl "$_tmpdir/all_dipl.json" \
    --slurpfile all_history "$_tmpdir/hist.json" \
    '$player_subs[0] as $player_subs | $curr[0] as $curr | $prev[0] as $prev | $dipl_events[0] as $dipl_events | $all_dipl[0] as $all_dipl | $all_history[0] as $all_history |
    {
      turn: $curr.turn,
      year: $curr.year,
      year_display: (if $curr.year < 0 then "\(-$curr.year) BC" else "\($curr.year) AD" end),
      player_count: ($curr.players | keys | length),
      players: [$curr.players | to_entries[] | {name: .key, nation: .value.nation, government: .value.government, is_alive: .value.is_alive}],

      totals: {
        total_cities: [$curr.players | to_entries[].value.cities] | add,
        total_units: [$curr.players | to_entries[].value.units] | add,
        total_population: [$curr.players | to_entries[].value.population // 0] | add,
        total_techs: [$curr.players | to_entries[].value.techs // 0] | add,
        total_wonders: [$curr.players | to_entries[].value.wonders // 0] | add,
        total_culture: [$curr.players | to_entries[].value.culture // 0] | add,
        total_pollution: [$curr.players | to_entries[].value.pollution // 0] | add,
        avg_literacy: ([$curr.players | to_entries[].value.literacy // 0] | add / ([$curr.players | to_entries[] | .value.literacy // 0] | length)),
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
          new_players: [$curr.players | keys[] | select(. as $k | $prev.players | has($k) | not)],
          government_changes: [
            $curr.players | to_entries[] |
            select($prev.players[.key] != null and .value.government != $prev.players[.key].government) |
            {player: .key, from: $prev.players[.key].government, to: .value.government}
          ],
          casualties: (
            ([$curr.players | to_entries[].value.units_killed // 0] | add) as $ck |
            ([$prev.players | to_entries[].value.units_killed // 0] | add) as $pk |
            ([$curr.players | to_entries[].value.units_lost // 0] | add) as $cl |
            ([$prev.players | to_entries[].value.units_lost // 0] | add) as $pl |
            ([$curr.players | to_entries[].value.units_built // 0] | add) as $cb |
            ([$prev.players | to_entries[].value.units_built // 0] | add) as $pb |
            {total_units_killed: ($ck - $pk), total_units_lost: ($cl - $pl), total_units_built: ($cb - $pb)}
          ),
          wonder_change: (([$curr.players | to_entries[].value.wonders // 0] | add) as $cw | ([$prev.players | to_entries[].value.wonders // 0] | add) as $pw | ($cw - $pw)),
          culture_change: (([$curr.players | to_entries[].value.culture // 0] | add) as $ccul | ([$prev.players | to_entries[].value.culture // 0] | add) as $pcul | ($ccul - $pcul)),
          pollution_change: (([$curr.players | to_entries[].value.pollution // 0] | add) as $cpol | ([$prev.players | to_entries[].value.pollution // 0] | add) as $ppol | ($cpol - $ppol))
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

      active_wars: [$all_dipl[] | select(.state == "War") | .players],
      active_alliances: [$all_dipl[] | select(.state == "Alliance") | .players],

      public_events: ($curr.public_events // []),

      score_leaders: [$curr.players | to_entries | sort_by(-.value.score)[:3] | .[].key],
      city_leaders: [$curr.players | to_entries | sort_by(-.value.cities)[:3] | .[].key],
      military_leaders: [$curr.players | to_entries | sort_by(-.value.units)[:3] | .[].key],
      culture_leaders: [$curr.players | to_entries | sort_by(-((.value.culture // 0)))[:3] | .[].key],
      wonder_holders: [$curr.players | to_entries[] | select((.value.wonders // 0) > 0) | {name: .key, count: .value.wonders}],
      spaceship_progress: [$curr.players | to_entries[] | select((.value.spaceship // 0) > 0) | {name: .key, progress: .value.spaceship}],

      trends: (
        [$all_history | sort_by(.turn) | .[-5:][]] |
        if length > 1 then {
          turns_covered: [.[].turn],
          total_cities_over_time: [.[].players | [to_entries[].value.cities] | add],
          total_units_over_time: [.[].players | [to_entries[].value.units] | add],
          total_score_over_time: [.[].players | [to_entries[].value.score] | add],
          total_pollution_over_time: [.[].players | [to_entries[].value.pollution // 0] | add],
          total_culture_over_time: [.[].players | [to_entries[].value.culture // 0] | add]
        } else null end
      ),

      notable: (
        [$curr.players | to_entries[] | select(.value.is_alive == false) | .key] as $dead |
        ($curr.players | to_entries | sort_by(-.value.score) | .[0]) as $top |
        ($curr.players | to_entries | sort_by(.value.score) | .[0]) as $bottom |
        ([$curr.players | to_entries[].value.score] | add / length) as $avg_score |
        {
          dead_players: $dead,
          score_leader: {name: $top.key, score: $top.value.score},
          score_last: {name: $bottom.key, score: $bottom.value.score},
          score_spread: ($top.value.score - $bottom.value.score),
          most_warlike: ($curr.players | to_entries | sort_by(-((.value.units_killed // 0))) | .[0] | {name: .key, kills: .value.units_killed}),
          most_casualties: ($curr.players | to_entries | sort_by(-((.value.units_lost // 0))) | .[0] | {name: .key, losses: .value.units_lost}),
          highest_pollution: ($curr.players | to_entries | sort_by(-((.value.pollution // 0))) | .[0] | {name: .key, pollution: .value.pollution}),
          most_cultured: ($curr.players | to_entries | sort_by(-((.value.culture // 0))) | .[0] | {name: .key, culture: .value.culture}),
          gov_distribution: ([$curr.players | to_entries[].value.government] | group_by(.) | map({gov: .[0], count: length}) | sort_by(-.count)),
          gov_outliers: [[$curr.players | to_entries[] | {name: .key, gov: .value.government}] | group_by(.gov)[] | select(length == 1) | .[0] | {name: .name, gov: .gov}],
          underdogs: [$curr.players | to_entries[] | select(.value.score < ($avg_score * 0.7)) | .key]
        }
      ),

      player_submissions: $player_subs
    }')

  rm -rf "$_tmpdir"
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
You are the editor-in-chief of "The Civ Chronicle", a newspaper covering a Freeciv multiplayer game. You run a real newsroom. Your reporters don't just recap what happened — they investigate, analyze, profile, predict, and provoke. Every issue should feel like a newspaper people actually want to read.

## Voice & era

Match the writing style to the game year:
- Ancient (4000–1000 BC): Chronicle/proclamation tone, mythic but readable.
- Classical (1000 BC–500 AD): Herodotus-meets-tabloid. Formal, slightly pompous.
- Medieval (500–1400 AD): Town crier, court gossip, chronicle style.
- Renaissance (1400–1800): Broadsheet pamphlet. Flowery but pointed.
- Modern (1800+): Modern newspaper. Punchy, analytical, editorial flair.

Always entertaining for a modern reader — era flavor is seasoning, not a barrier.

## What makes good journalism

DO NOT just summarize the turn's data points. That produces boring, repetitive copy. Instead:

- **Analyze, don't summarize**: What do the numbers *mean*? Find the one or two real stories this turn and tell them well.
- **Use trends**: "For the third straight turn..." — show trajectories, not just snapshots.
- **Speculate forward**: What should readers watch for? Who's positioned to make a move?
- **Vary the approach**: One issue might profile a player. Another might investigate pollution. Don't repeat the same formula.

BE CONCISE. Each section should be 1-2 short paragraphs, not feature-length articles. A tight column with one sharp insight beats three paragraphs of elaboration. Write like a newspaper with limited column inches — every sentence must earn its place.

## Data available

- **players**: names, nations, government types (public knowledge)
- **totals**: aggregate world stats (cities, units, population, techs, wonders, culture, pollution, literacy)
- **deltas**: changes since last turn (casualties, government changes, wonder/culture/pollution shifts, new cities)
- **trends**: 5-turn rolling data for cities, units, score, pollution, culture — use these to identify trajectories
- **notable**: computed story hooks — score spread, most warlike player, biggest casualties, underdogs, unusual government holdouts, dead players
- **diplomacy_events / active_wars / active_alliances**: diplomatic landscape
- **public_events**: wonder completions, revolts, city foundings
- **wonder_holders / spaceship_progress / culture_leaders**: achievement data
- **player_submissions**: Correspondence between the editor and in-game leaders. Includes player messages and editor replies, with a `pub_status` field showing whether each was already published (e.g. "Published in edition 99") or "Not yet published". You have FULL editorial discretion to quote, paraphrase, or reference any material. Treat player messages as on-the-record statements from public figures. Prefer unpublished material — avoid re-quoting things already published in a previous edition unless following up on a story. Weave the best material into articles naturally. Not everything needs to be used.
- **recent_headlines**: Headlines from the last ~5 editions. Use this to avoid rehashing stories that were already covered. If something was a headline 2 turns ago, it is NOT news anymore unless there is a genuinely new development in THIS turn's data (a new diplomacy_event, a new public_event, a new delta).

## Information rules

- **PUBLIC** (report freely): diplomacy, wars, alliances, government types, aggregate totals, wonder completions, combat casualties, city foundings, rankings, nations, spaceship progress, who holds wonders, government changes, trends
- **PRIVATE** (never reveal): per-player gold, per-player unit counts or compositions, per-player tech counts, research targets, city production, per-player happiness/literacy/pollution
- Fictional quotes from in-game player leaders are encouraged — they are public figures being quoted by the press. But use them where they serve the story, not as a formula. Some stories need quotes; some are better without them.
- **Player-nation cross-referencing**: On first mention of a player in each section, naturally include their nation (e.g. "Shogun of the English", "Kroony, the Atlantean chieftain"). On first mention of a nation, include the player name (e.g. "the English, led by Shogun"). Do this naturally within the prose — do NOT use parenthetical annotations like "Shogun (English)". After the first mention in a section, just use whichever name fits.

## Structure

The newspaper has these sections, but you have FULL editorial control over their weight and focus:

- **Front Page**: The ONE story that matters most, told in 2-3 tight paragraphs. Not a summary of everything.
- **Economy**: 1-2 paragraphs. One insight about the economic situation — inequality, governance, pollution, whatever's interesting.
- **Military**: 1-2 paragraphs. The balance of power, who's fighting, what it means.
- **Society**: 1-2 paragraphs. Culture, science, the human side.
- **Opinion Column**: 2-3 paragraphs IN THE VOICE of a real historical figure alive at the game year. Must faithfully reproduce their actual writing style. React to specific events, not generic philosophy.
- **Letters to the Editor**: 2-3 SHORT letters (2-3 sentences each) from fictional citizens. Each letter MUST be written by a citizen of a specific player's nation, from a plausible city in that civilization (e.g. "Ottawa, Canada" or "Tokyo, Japan" or "Valletta, Malta"). The letter should reflect that citizen's lived experience under their government — a farmer in a communist state has different complaints than a merchant in a democracy. Reference specific events affecting their nation.
- **Classifieds**: 3-6 classified ads (vary the number each issue). These should read like REAL classified ads from a newspaper of the game's current era — not jokes with punchlines, but genuinely plausible ads that happen to be funny because of the game context. Each ad MUST include era-appropriate contact info (ancient: "inquire at the eastern gate" / medieval: "send word to the guild hall on Bridge Street" / modern: "call 555-0142" or "email jobs@company.com" or a PO Box). Include prices, quantities, locations, requirements. Some categories: jobs/help wanted, real estate, goods for sale, services, lost & found, personals, legal notices. Plain text only, no HTML tags.

Every section gets an era-appropriate byline. Keep the same reporters across issues.

## Continuity

When given a PREVIOUS issue:
- Keep the same reporter staff (or explain departures)
- Follow up on previous stories ONLY if there is new data to report (a new event, a meaningful stat change, a new player message). Do not rehash or re-announce something that was already a headline.
- Issue corrections when past speculation proved wrong (be funny about it)
- Build running narratives — the space race, a rivalry, an underdog's rise
- Check recent_headlines: if a story was already headlined, find a DIFFERENT angle or a different story entirely. Every edition needs fresh news.

## Headline

Punchy, dramatic, like a real newspaper front page. Do NOT include turn number or year — those are in the masthead.

## Output format

Return JSON with this exact structure:
{
  "headline": "...",
  "sections": {
    "front_page": {"byline": "reporter name and title", "content": "..."},
    "economy": {"byline": "reporter name and title", "content": "..."},
    "military": {"byline": "reporter name and title", "content": "..."},
    "society": {"byline": "reporter name and title", "content": "..."}
  },
  "opinion": {
    "author": "real historical figure alive at the game year",
    "author_title": "their real title",
    "title": "column title",
    "content": "..."
  },
  "letters": [
    {"author": "citizen name, role, city, nation", "content": "..."},
    {"author": "citizen name, role, city, nation", "content": "..."}
  ],
  "ads": ["classified ad 1", "classified ad 2", "...(3-6 total, vary each issue)"],
  "corrections": "correction text or null",
  "illustration_caption": {
    "credit": "credit line as it would appear in a newspaper of this era (e.g. 'Photograph by Dorothea Lange, AP'). Use the era-appropriate medium (carving/painting/engraving/photograph). Do NOT use words like 'period' or 'era' or 'ancient'. This is a newspaper from THAT day.",
    "description": "plain text description of what the image depicts"
  }
}

All content fields should use simple HTML (<p>, <strong>, <em>) for formatting.
SYSPROMPT
)

  local prev_issue="$2"

  local user_prompt="Write the gazette for Turn ${turn} (${year_display}).

Game context:
${context}"

  if [ -n "$prev_issue" ] && [ "$prev_issue" != "null" ]; then
    user_prompt="${user_prompt}

Previous issue of The Civ Chronicle:
${prev_issue}"
  fi

  local request_body response content

  if [ "$GAZETTE_PROVIDER" = "anthropic" ]; then
    local _tmpsys=$(mktemp) _tmpusr=$(mktemp)
    printf '%s' "$system_prompt" > "$_tmpsys"
    printf '%s' "$user_prompt" > "$_tmpusr"
    request_body=$(jq -n \
      --rawfile system "$_tmpsys" \
      --rawfile user "$_tmpusr" \
      '{
        model: "claude-opus-4-6",
        max_tokens: 8000,
        system: $system,
        messages: [
          {role: "user", content: $user}
        ],
        temperature: 0.9
      }')
    rm -f "$_tmpsys" "$_tmpusr"

    local _tmpbody=$(mktemp)
    echo "$request_body" > "$_tmpbody"
    response=$(curl -s --max-time 120 \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "Content-Type: application/json" \
      -d "@$_tmpbody" \
      "https://api.anthropic.com/v1/messages")
    rm -f "$_tmpbody"

    content=$(echo "$response" | jq -r '.content[0].text // empty')

    if [ -z "$content" ]; then
      echo "[gazette] Anthropic call failed for turn $turn" >&2
      echo "$response" | jq . >&2 2>/dev/null || echo "$response" >&2
      return 1
    fi

    # Claude may wrap JSON in markdown code fences — strip them
    content=$(echo "$content" | sed '/^```json$/d' | sed '/^```$/d')
  else
    local _tmpsys=$(mktemp) _tmpusr=$(mktemp)
    printf '%s' "$system_prompt" > "$_tmpsys"
    printf '%s' "$user_prompt" > "$_tmpusr"
    request_body=$(jq -n \
      --rawfile system "$_tmpsys" \
      --rawfile user "$_tmpusr" \
      '{
        model: "gpt-5.4",
        messages: [
          {role: "system", content: $system},
          {role: "user", content: $user}
        ],
        temperature: 0.9,
        max_completion_tokens: 8000,
        response_format: {type: "json_object"}
      }')
    rm -f "$_tmpsys" "$_tmpusr"

    local _tmpbody=$(mktemp)
    echo "$request_body" > "$_tmpbody"
    response=$(curl -s --max-time 60 \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      -d "@$_tmpbody" \
      "https://api.openai.com/v1/chat/completions")
    rm -f "$_tmpbody"

    content=$(echo "$response" | jq -r '.choices[0].message.content // empty')

    if [ -z "$content" ]; then
      echo "[gazette] OpenAI call failed for turn $turn" >&2
      echo "$response" | jq . >&2 2>/dev/null || echo "$response" >&2
      return 1
    fi
  fi

  # Validate it's JSON with expected fields
  if ! echo "$content" | jq -e '.headline and .sections and .opinion and .letters' >/dev/null 2>&1; then
    echo "[gazette] Invalid response format for turn $turn" >&2
    echo "$content" >&2
    return 1
  fi

  echo "$content"
}

# ---------------------------------------------------------------------------
# Generate a front-page illustration using Gemini image generation
# ---------------------------------------------------------------------------
generate_illustration() {
  local headline="$1"
  local year="$2"
  local target_turn="$3"
  local front_page_text="$4"
  local art_credit="$5"
  local illustration_desc="$6"

  # API key: env var > .env file > file in save dir
  local api_key="${GEMINI_API_KEY:-}"
  if [ -z "$api_key" ] && [ -f "$SCRIPT_DIR/.env" ]; then
    api_key=$(grep '^GEMINI_API_KEY=' "$SCRIPT_DIR/.env" | head -1 | sed 's/^GEMINI_API_KEY=//' | tr -d '[:space:]"'"'")
  fi
  if [ -z "$api_key" ] && [ -f "$SAVE_DIR/gemini_api_key" ]; then
    api_key=$(cat "$SAVE_DIR/gemini_api_key" | tr -d '[:space:]')
  fi
  if [ -z "$api_key" ]; then
    echo "[gazette] No Gemini API key found, skipping illustration" >&2
    return 1
  fi

  # Pick art style based on era
  local art_style
  if [ "$year" -lt -1000 ] 2>/dev/null; then
    art_style="ancient Mesopotamian/Egyptian stone relief carving style, carved into sandstone, hieroglyphic border elements"
  elif [ "$year" -lt 500 ] 2>/dev/null; then
    art_style="classical Greek/Roman mosaic or red-figure pottery style, terracotta and black tones"
  elif [ "$year" -lt 1400 ] 2>/dev/null; then
    art_style="medieval illuminated manuscript style, gold leaf accents, rich colors on parchment"
  elif [ "$year" -lt 1800 ] 2>/dev/null; then
    art_style="Renaissance woodcut engraving style, fine black ink crosshatching on cream paper"
  else
    art_style="vintage newspaper editorial illustration, pen and ink sketch style, crosshatched shading"
  fi

  # Strip HTML from front page text for the prompt
  local clean_text
  clean_text=$(echo "$front_page_text" | sed 's/<[^>]*>//g' | head -c 500)

  # Add artist style if available
  local artist_style=""
  if [ -n "$art_credit" ]; then
    artist_style="In the style described by: ${art_credit}. "
  fi
  local scene_desc="${clean_text}"
  if [ -n "$illustration_desc" ]; then
    scene_desc="Scene to depict: ${illustration_desc}. Context: ${clean_text}"
  fi

  local prompt="Generate a small newspaper illustration. ${artist_style}Style: ${art_style}. ${scene_desc}. No text or words in the image. Square format, detailed."

  local request_body
  request_body=$(jq -n \
    --arg prompt "$prompt" \
    '{
      contents: [{
        parts: [{text: $prompt}]
      }],
      generationConfig: {
        responseModalities: ["Text", "Image"],
        temperature: 0.8,
        imageConfig: {
          imageSize: "1K"
        }
      }
    }')

  echo "[gazette] Generating illustration for turn $target_turn..." >&2
  local response
  response=$(curl -s --max-time 60 \
    -H "x-goog-api-key: $api_key" \
    -H "Content-Type: application/json" \
    -d "$request_body" \
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-image-preview:generateContent")

  # Extract base64 image data from response
  local image_data
  image_data=$(echo "$response" | jq -r '.candidates[0].content.parts[] | select(.inlineData) | .inlineData.data // empty' 2>/dev/null | head -1)

  if [ -z "$image_data" ]; then
    echo "[gazette] Gemini image generation failed for turn $target_turn" >&2
    echo "$response" | jq -r '.error.message // empty' >&2 2>/dev/null
    return 1
  fi

  # Save image to persistent storage and symlink to webroot
  local filename="gazette-${target_turn}.png"
  echo "$image_data" | base64 -d > "$SAVE_DIR/$filename"
  ln -sf "$SAVE_DIR/$filename" "$WEBROOT/$filename"
  echo "[gazette] Saved illustration: $filename" >&2
  echo "$filename"
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

  # Get previous issue for continuity
  local prev_issue
  prev_issue=$(echo "$GAZETTE_JSON" | jq --argjson t "$((target_turn - 1))" '[.[] | select(.turn == $t)] | .[0] // null')

  # Get recent headlines so the AI knows what's already been covered
  local recent_headlines
  recent_headlines=$(echo "$GAZETTE_JSON" | jq --argjson t "$target_turn" \
    '[.[] | select(.turn < $t) | {turn: .turn, year_display: .year_display, headline: .headline}] | sort_by(-.turn) | .[:5]')

  # Inject recent headlines into context
  context=$(echo "$context" | jq --argjson rh "$recent_headlines" '. + {recent_headlines: $rh}')

  local entry
  entry=$(generate_entry "$context" "$prev_issue") || return 1

  local year
  year=$(echo "$context" | jq -r '.year')
  local year_display
  year_display=$(echo "$context" | jq -r '.year_display')

  # Generate front-page illustration
  local illustration=""
  local headline fp_content ill_artist ill_desc
  headline=$(echo "$entry" | jq -r '.headline')
  fp_content=$(echo "$entry" | jq -r '.sections.front_page.content // .sections.front_page // ""')
  ill_credit=$(echo "$entry" | jq -r '.illustration_caption.credit // ""')
  ill_desc=$(echo "$entry" | jq -r '.illustration_caption.description // ""')
  illustration=$(generate_illustration "$headline" "$year" "$target_turn" "$fp_content" "$ill_credit" "$ill_desc") || true

  # Remove existing entry for this turn if rebuilding
  GAZETTE_JSON=$(echo "$GAZETTE_JSON" | jq --argjson t "$target_turn" '[.[] | select(.turn != $t)]')

  # Add new entry (write entry to temp file to avoid ARG_MAX)
  local _tmpentry=$(mktemp)
  echo "$entry" > "$_tmpentry"
  GAZETTE_JSON=$(echo "$GAZETTE_JSON" | jq --argjson t "$target_turn" --argjson y "$year" \
    --arg yd "$year_display" --slurpfile entry "$_tmpentry" --arg img "$illustration" \
    '$entry[0] as $entry | . + [{
      turn: $t,
      year: $y,
      year_display: $yd,
      headline: $entry.headline,
      sections: $entry.sections,
      opinion: $entry.opinion,
      letters: $entry.letters,
      ads: ($entry.ads // []),
      corrections: ($entry.corrections // null),
      illustration: (if $img != "" then $img else null end),
      illustration_caption: ($entry.illustration_caption // null)
    }] | sort_by(.turn)')
  rm -f "$_tmpentry"

  # Save after each entry
  echo "$GAZETTE_JSON" > "$GAZETTE_FILE.tmp"
  mv "$GAZETTE_FILE.tmp" "$GAZETTE_FILE"
  ln -sf "$GAZETTE_FILE" "$WEBROOT/gazette.json"

  # Mark unpublished player messages as used in this edition
  local DB_PATH="${DB_PATH:-/data/saves/freeciv.sqlite}"
  if [ -f "$DB_PATH" ]; then
    sqlite3 "$DB_PATH" "UPDATE editor_messages SET published=$target_turn WHERE role='player' AND published=0;" 2>/dev/null || true
  fi

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
