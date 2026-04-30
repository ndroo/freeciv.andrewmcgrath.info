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

# Shared diplomacy-event classifier (defines CLASSIFY_EVENT_JQ_DEF)
# shellcheck source=lib_diplomacy.sh
. "$SCRIPT_DIR/lib_diplomacy.sh"
# shellcheck source=lib_log.sh
. "$SCRIPT_DIR/lib_log.sh"

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

  # Per-region capitals + terrain — used by the weather/augury section
  # to write per-nation forecasts based on each capital's actual climate.
  # Best-effort; failures degrade gracefully to an empty regions list.
  local latest_save="$SAVE_DIR/save-latest.sav.gz"
  local extract_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/python/bin/extract_capitals.py"
  if [ -f "$latest_save" ] && [ -f "$extract_script" ]; then
    python3 "$extract_script" "$latest_save" 2>/dev/null > "$_tmpdir/regions.json" \
      || echo '{"regions":[]}' > "$_tmpdir/regions.json"
  else
    echo '{"regions":[]}' > "$_tmpdir/regions.json"
  fi

  local context
  # The classifier def (CLASSIFY_EVENT_JQ_DEF) is concatenated at the front
  # of the jq program so `classify_event` is in scope throughout.
  context=$(jq -n \
    --slurpfile player_subs "$_tmpdir/subs.json" \
    --slurpfile curr "$_tmpdir/curr.json" \
    --slurpfile prev "$_tmpdir/prev.json" \
    --slurpfile dipl_events "$_tmpdir/dipl_events.json" \
    --slurpfile all_dipl "$_tmpdir/all_dipl.json" \
    --slurpfile all_history "$_tmpdir/hist.json" \
    --slurpfile regions "$_tmpdir/regions.json" \
    "$CLASSIFY_EVENT_JQ_DEF"'
    $player_subs[0] as $player_subs | $curr[0] as $curr | $prev[0] as $prev | $dipl_events[0] as $dipl_events | $all_dipl[0] as $all_dipl | $all_history[0] as $all_history | $regions[0] as $regions_data |
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

      diplomacy_events: [$dipl_events[] | classify_event],
      treaties_signed_this_turn: [$dipl_events[] | classify_event | select(.negotiated_this_turn == true)],
      automatic_transitions_this_turn: [$dipl_events[] | classify_event | select(.negotiated_this_turn == false)],

      active_wars: [$all_dipl[] | select(.status == "War") | .players],
      active_alliances: [$all_dipl[] | select(.status == "Alliance") | .players],

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

      player_submissions: $player_subs,
      capitals: ($regions_data.regions // [])
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
You are the editor-in-chief of "The Civ Chronicle", a multi-page newspaper covering a Freeciv multiplayer game. You run a real newsroom. Your reporters investigate, analyze, profile, predict, and provoke. Every issue should feel like a newspaper readers actually want to flip through.

YOU ARE THE EDITOR. You decide which stories matter, how the paper is laid out, what sections appear, and where images go. The structure should serve the news, not the other way around.

## Voice & era

Match the writing style to the game year:
- Ancient (4000–1000 BC): Chronicle/proclamation tone, mythic but readable.
- Classical (1000 BC–500 AD): Herodotus-meets-tabloid. Formal, slightly pompous.
- Medieval (500–1400 AD): Town crier, court gossip, chronicle style.
- Renaissance (1400–1800): Broadsheet pamphlet. Flowery but pointed.
- Modern (1800+): Modern newspaper. Punchy, analytical, editorial flair.

Always entertaining for a modern reader — era flavor is seasoning, not a barrier.

## What makes good journalism

- **Analyze, don't summarize**: What do the numbers MEAN? Find the one or two real stories and tell them well.
- **Use trends**: "For the third straight turn..." — trajectories, not snapshots.
- **Speculate forward**: Who's positioned to make a move?
- **Vary the approach AND the structure**: A blockbuster war turn should look completely different from a quiet diplomatic turn. Every edition should feel unique.

BE CONCISE. Sections are 1–3 short paragraphs unless the story demands more. Tight columns with one sharp insight beat three paragraphs of elaboration.

## Data available

- **players** (names, nations, governments — public)
- **totals** (cities, units, population, techs, wonders, culture, pollution, literacy)
- **deltas** (changes since last turn)
- **trends** (5-turn rolling data)
- **notable** (computed story hooks — score spread, warlike, casualties, underdogs)
- **diplomacy_events / active_wars / active_alliances**, with `negotiated_this_turn` flag.
- **CRITICAL — diplomacy semantics**: Freeciv has AUTOMATIC state transitions that look like signed treaties but are not. `peace_took_effect`, `armistice_began`, `first_contact` are AUTOMATIC. Only events with `negotiated_this_turn: true` are real deals struck this turn (`war_declared`, `ceasefire_signed`, `peace_signed`, `alliance_formed`). When counting player activity, count only `treaties_signed_this_turn`.
- **public_events** (wonders, revolts, city foundings)
- **wonder_holders / spaceship_progress / culture_leaders**
- **player_submissions**: real correspondence with players. `pub_status` shows whether each was published before. You have FULL editorial discretion. Prefer unpublished material.
- **recent_headlines** + **recent_section_kinds**: the previous editions' shape and stories. **Do NOT use the same section lineup as the previous edition.** Pick a different shape — let the news of THIS turn dictate which sections appear.

## Information rules

- **PUBLIC** (report freely): diplomacy, wars, alliances, government types, aggregate totals, wonder completions, combat casualties, city foundings, rankings, nations, spaceship progress, government changes, trends.
- **PRIVATE** (never reveal): per-player gold, per-player unit counts or compositions, per-player tech counts, research targets, city production, per-player happiness/literacy/pollution.
- Fictional quotes from leaders are encouraged when they serve the story.
- Cross-reference player ↔ nation naturally on first mention ("Shogun of the English"). After that use whichever fits.

## Output structure (schema_version 2)

The paper is **2 pages typically, 1 if news is sparse, 3–4 for major occasions** (war declarations, deaths, anniversaries). YOU choose. Each page is an array of sections. YOU choose which kinds and in what order.

### REQUIRED in every edition
Every edition MUST include AT LEAST one of each of:
- `letters` — letters to the editor (always; 2–3 letters; they're the heart of the paper)
- `puzzle` — a crossword (always; readers expect it)
- `ads` — classifieds with EXACTLY 6 entries (the funniest section, never skip it)

These three are non-negotiable. They typically live on the last page.

### Page composition advice
Aim for **3–5 sections per page** with a visual mix of full-width pieces (lead, breaking, puzzle, letters, ads) and column-pieces (column/feature/society/etc.). The renderer arranges columns in a 2-up grid, so pair them so adjacent columns are roughly the same length. Don't generate so many sections that pages end up sparse.

Available section kinds (use the ones that fit the news — don't force every kind into every edition):

- `lead` — the splash story at the top of page 1. Almost every edition has one. {title, byline, content, lead_image_id?}
- `column` — focused analysis on one topic (Economy, Military, Society…). 0–3 per edition. {title, byline, content, lead_image_id?}
- `feature` — longer profile or investigative piece. {title, byline, content}
- `opinion` — op-ed in voice of a REAL historical figure alive at the game year. {author, author_title, title, content}
- `interview` — quote-driven piece on one player. Use when a player is doing something genuinely interesting. {subject, byline, content}
   - For Q&A format, mark each question prefix with `<em class="q">` (renders as a small-caps brown label on its own line). Plain `<em>` stays italic and inline — use it for normal emphasis or pull-quotes WITHOUT triggering label styling. Example: `<p><em class="q">Q. On the war:</em> "I never wanted this," the king said. <em>Privately</em>, advisors disagree.</p>`
- `letters` — letters to the editor. {items: [{from, title?, body}]}
   - **Letter material vs. inquiry material**: Real player correspondence falls into two buckets. **Letter material** = public-facing rhetoric, opinions, declarations, manifestos, cheers, jeers — things a leader would WANT printed. Speech-act: addressing readers and other leaders. **Inquiry material** = private requests TO the editor for information, intelligence, or favors. Speech-act: addressing the paper itself. Inquiry material does NOT belong as a printed letter — if it's newsworthy, paraphrase or quote it inside the editorial body (lead/column/feature/interview). Reprinting a back-office DM verbatim as a "letter" reads as a leak.
   - **Don't double-publish**: if you already used a piece of correspondence in an editorial section (interview, feature, lead quote), don't ALSO reprint it as a letter. Pick one venue.
- `obituary` — a player has died, or a great city has fallen. RARE. {title, content}
- `looking_back` — retrospective: today's events parallel an earlier turn, or it's an anniversary edition. Use only when there is a real parallel. {title, content}
- `dispatch` — foreign-correspondent angle from one nation. {title, byline, content}
- `breaking` — small high-priority sidebar (1 paragraph, wire-service style). {title, content}
- `puzzle` — REQUIRED in every edition. Almost always a crossword (the renderer builds the grid for you):
   - `{ "type": "crossword", "title": "...", "entries": [{"word": "BRONZE", "clue": "Hard alloy..."}, ...] }` — give 8–12 entries, words 3–9 letters, ALL CAPS, no spaces or punctuation. The renderer fits them into a real intersecting grid client-side, so make sure several words share letters (otherwise placement fails and they're dropped from the grid). Clues should be era-appropriate AND reference real game-state from this turn (player names, nations, recent events) — that's what makes it fun.
   - **CRITICAL — no repeats**: the context provides `recent_crossword_words` listing every word used in any prior edition's crossword. **Every word in `entries` must NOT appear in `recent_crossword_words`.** Crosswords get stale fast when the same answers (BRONZE, CHARIOT, OATH, RIVER) come back turn after turn. Reach for fresher answers — domain-specific terms tied to *this* turn's events. If you genuinely can't avoid 1-2 reuses, prefer rephrasing the clue to give the same word a different angle.
   - **CRITICAL — real names**: when referencing in-game places or things, use the player-chosen names from the `capitals` array (e.g. if DetectiveG's Ecuadorian capital is "Fuck Off!!!" then that is the city, NOT "Quito" — don't fall back to real-world geography). Same for nations and players: use exactly the names you see in the context.
   - Occasionally vary with `{ "type": "cipher", "title": "...", "cipher_text": "WKLV LV D PHVVDJH", "hint": "Caesar shift, key 3" }` for a change of pace, but the crossword is the default.
- `sports` — era-appropriate athletics (ancient foot races → chariot races → jousting → fencing → modern sports). {title, byline?, report?, results:[{match, outcome}]}
- `weather` (or `augury`) — era-styled forecast page. Always slightly absurd. Schema (use any combination of these — `regions` is the showpiece, the rest are supplementary):
   - `label` — section title (e.g. "The Augur's Forecast — 1450 BC")
   - `forecast` — one poetic headline forecast line (the "tomorrow's weather: war" tone)
   - `regions` — **the headline feature**: per-nation weather grounded in each capital's actual terrain. Schema: `[{ "nation": "Australian", "capital": "Sydney", "terrain": "Plains", "icon": "☀️", "forecast": "Hot wind off the inland sea, scribes complain.", "omen": "Locusts sighted east." }]`. The `capitals` array in the context gives you each player's capital + terrain ground-truth — use it. **Pick exactly 3 OR exactly 6 nations** (the renderer is a 3-column grid, so 3 = one row, 6 = two rows; any other count leaves empty cells). Choose the most newsworthy this turn: war participants, score leaders, anyone whose weather ties to a current storyline, plus 1-2 underdog/atmospheric picks for colour. Rotate the selection across editions so different nations get the spotlight over time. Pick `icon` from: ☀️ ⛅ ☁️ 🌧️ ⛈️ 🌪️ ❄️ 🌨️ 🌫️ 🌬️ 🦗 🔥 🌊 🌋 ☄️ 🌑 — match the climate (desert→☀️, tundra→❄️, jungle→🌧️, war zone→🔥, etc.). Forecast lines should be SHORT — one tight sentence each. `omen` is optional and even shorter. **Use the player-chosen capital names verbatim** from the `capitals` array — never substitute real-world geography (e.g. "Quito" for whatever the Ecuadorian player actually named their city).
   - `outlooks` — array of 2–4 world-wide hazard watches with severity: `[{ "kind": "flood", "level": "moderate", "note": "Tigris swells" }, { "kind": "locust", "level": "watch", "note": "Swarm beyond Ur" }]`. Valid `level`: `low | moderate | watch | severe`. `kind` is short (1-2 words, era-appropriate: flood, fire, locust, plague, frost, drought, dust storm, eclipse, comet, etc.). `note` is one short sentence. Hazards should track real game events when possible (war = "war smoke severe", lots of unsettled tiles = "drought watch", etc.).
   Make the section feel like a real almanac page — short, slightly ominous, era-true. The per-region grid is the most interesting part because it ties the weather to the actual game map.
- `lottery` — auspicious numbers / temple readings. {label, numbers:[5 ints], note?}
- `marketplace` — commodity prices ledger. {title, items:[{commodity, price}]}
- `rumour_mill` — 3–5 one-line gossip snippets. {content with <p> per line}
- `etiquette` — era-appropriate manners column. {title, byline, content}
- `serial_fiction` — continuing story across editions. {title, byline, content}
- `image` — standalone visual block. {image_id, size: "full|half|aside"}
- `corrections` — usually last on the final page. {content}
- `ads` — classifieds. Usually last on the final page. {items:[strings]}

Recurring features (sports, weather, lottery, puzzle, marketplace) are an opportunity to give the paper personality without requiring big news. Rotate them — not every edition has every recurring section.

## Images

You may include up to **6 images**, typically 2–3. The image generator (Gemini) makes one image per `images[]` entry from your prompt. Each image gets:
- `id` (your label, e.g. "im1")
- `prompt` — concrete visual scene. ONE specific moment, one or two subjects, identifiable action and setting. BAD: "a nation at a crossroads". GOOD: "Two robed envoys shake hands across a stone table as scribes record the peace".
- `caption` — what runs underneath, like a real newspaper photo caption.
- `credit` — era-appropriate medium (carving / engraving / woodcut / photograph).

Then place the image in the layout via:
- `lead_image_id` on a section → hero image at the top of that section
- `{{img:id}}` token inside a section's `content` HTML → inline figure at that exact spot
- A standalone `{kind: "image", image_id: "imN", size: "full|half|aside"}` section → striking single-image block

Only generate an image if there is a concrete scene worth showing. A talky diplomatic edition might use only 1; a war edition might use 4.

## Classifieds

Era-appropriate. Real-classifieds-with-context, not punchlines. Each ad needs era-appropriate contact info (ancient: "inquire at the eastern gate" / medieval: "send word to the guild hall on Bridge Street" / modern: "call 555-0142"). Plain text, no HTML.

## Continuity

When given a PREVIOUS issue (`previous_issue` in context) and `recent_headlines`:
- Keep the same reporter staff. Recurring bylines (Mira Vance, Naram-Ettu, etc.) build the paper's identity over time.
- Follow up on previous stories ONLY if there's new data. Don't re-announce yesterday's headline.
- Issue corrections when past speculation proved wrong (be funny about it).
- Build running narratives — a space race, a rivalry, an underdog's rise.

## Headline

Punchy, dramatic. Do NOT include turn number or year — those are in the masthead.

## Output format

Return JSON with EXACTLY this top-level shape:

{
  "schema_version": 2,
  "headline": "...",
  "edition_label": null,           // optional banner like "Anniversary Issue" — usually null

  "images": [                      // 0–6 images (2–3 typical)
    { "id": "im1", "prompt": "...", "caption": "...", "credit": "..." }
  ],

  "pages": [                       // **3–5 pages — never more.** Aim for 4.
    {
      "page_number": 1,
      "sections": [
        { "kind": "lead", "title": "...", "byline": "...", "lead_image_id": "im1", "content": "<p>...</p>" }
        // ... more sections in order
      ]
    }
    // ... more pages
  ]
}

All `content` strings use simple HTML (<p>, <strong>, <em>). No <script>, no <img> (use the image system).

## Page balance — VERY IMPORTANT

Pages are rendered as a printed broadsheet whose height locks to the TALLEST page. A short page next to a tall page leaves dead whitespace, which looks unprofessional. Therefore:

- **Aim for 3–5 pages** total. Four is the sweet spot. Six or seven pages of thin content reads as padding.
- Each page should hold **roughly the same amount of text** as its siblings. Don't put a giant lead + tiny page-2.
- Single-column sections will pair into rows of two — so each page should have either a span-all section (lead/breaking/puzzle/letters/ads/corrections) or an EVEN number of single-col sections (column/feature/dispatch/opinion/interview), so no row ends up half-empty.
- The weather/augury section is full-width when it has `regions[]` — it tends to be tall, so put it on a page where it's the dominant feature with maybe one short partner.
- Recurring features (sports, marketplace, lottery, weather) on the LAST page should NOT each get their own page. Combine 2–3 onto one page.

You can experiment with section kinds beyond the documented list — the renderer falls back to a generic prose block for unknown kinds. But prefer the documented kinds when they fit.
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
    local _tmpsys=$(mktemp) _tmpusr=$(mktemp) _tmpout=$(mktemp)
    printf '%s' "$system_prompt" > "$_tmpsys"
    printf '%s' "$user_prompt" > "$_tmpusr"

    # Use the streaming Python helper so the user sees live token/sec
    # progress on stderr instead of 2-3 minutes of dead air. The helper
    # writes the assembled text to stdout; bash captures that into
    # `content`. Stderr is left attached to the terminal.
    local _helper
    _helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/python/bin/anthropic_complete.py"
    if [ ! -x "$_helper" ]; then
      echo "[gazette] ERROR: streaming helper not found at $_helper" >&2
      rm -f "$_tmpsys" "$_tmpusr" "$_tmpout"
      return 1
    fi

    local sys_size usr_size
    sys_size=$(wc -c < "$_tmpsys" | tr -d ' ')
    usr_size=$(wc -c < "$_tmpusr" | tr -d ' ')
    echo "[gazette] Calling Anthropic (model=claude-opus-4-6, system=${sys_size}B user=${usr_size}B)..." >&2

    local _t0 _elapsed _exit
    _t0=$(date +%s)
    if ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" python3 "$_helper" \
         --model claude-opus-4-6 \
         --max-tokens 8000 \
         --temperature 0.9 \
         "$_tmpsys" "$_tmpusr" > "$_tmpout"; then
      _exit=0
    else
      _exit=$?
    fi
    _elapsed=$(($(date +%s) - _t0))
    rm -f "$_tmpsys" "$_tmpusr"

    if [ "$_exit" -ne 0 ]; then
      echo "[gazette] Anthropic helper failed (exit $_exit) for turn $turn after ${_elapsed}s" >&2
      rm -f "$_tmpout"
      return 1
    fi

    content=$(cat "$_tmpout")
    rm -f "$_tmpout"

    if [ -z "$content" ]; then
      echo "[gazette] Anthropic returned empty content for turn $turn" >&2
      return 1
    fi
    echo "[gazette] Got ${#content} chars of content from Anthropic in ${_elapsed}s" >&2

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

  # Validate v2 structural integrity (not content correctness — unknown
  # section kinds are intentionally allowed). If schema_version != 2 we
  # accept it as legacy v1 if it has `sections` (some prompts may slip).
  local validation_ok=false
  if echo "$content" | jq -e '.schema_version == 2 and (.headline | length > 0) and (.pages | type == "array") and (.pages | length > 0) and (.pages | all(.sections | type == "array"))' >/dev/null 2>&1; then
    # Image cap (≤ 6) and inline-token resolution check
    local img_count token_unresolved
    img_count=$(echo "$content" | jq '.images // [] | length')
    if [ "$img_count" -gt 6 ] 2>/dev/null; then
      echo "[gazette] Validation failed: $img_count images (max 6)" >&2
    else
      # Confirm every {{img:id}} and lead_image_id has a matching image entry.
      token_unresolved=$(echo "$content" | jq -r '
        (.images // []) | map(.id) as $ids |
        [
          (.. | objects | select(has("lead_image_id")) | .lead_image_id),
          (.. | strings | scan("\\{\\{img:([a-z0-9_-]+)\\}\\}") | .[0])
        ] | flatten | map(select(. != null and (. as $i | $ids | index($i) == null)))
        | unique | join(",")
      ')
      if [ -n "$token_unresolved" ]; then
        echo "[gazette] Validation failed: unresolved image refs: $token_unresolved" >&2
      else
        validation_ok=true
      fi
    fi
  elif echo "$content" | jq -e '.headline and .sections and .opinion and .letters' >/dev/null 2>&1; then
    # v1 legacy fallback — old prompts or model regression. Accept it.
    echo "[gazette] Note: model returned v1-style response (no schema_version=2)" >&2
    validation_ok=true
  fi

  if [ "$validation_ok" != "true" ]; then
    echo "[gazette] Invalid response format for turn $turn" >&2
    echo "$content" >&2
    return 1
  fi

  echo "$content"
}

# ---------------------------------------------------------------------------
# Era-appropriate art-style pool. Each era returns a multi-line list of
# distinct media options. The image generator picks one per image at
# random so a single edition doesn't end up with three identical
# orange tablets.
#
# Crucially every entry says the work is FRESHLY MADE with vivid
# pigments — the weathered-orange aesthetic that dominates AI Bronze-Age
# imagery is millennia of fade, not how the originals actually looked.
# We want to depict the world AT the year, not as we'd find its
# artefacts in a museum today.
# ---------------------------------------------------------------------------
_art_styles_for_year() {
  local year="$1"
  if [ "$year" -lt -1000 ] 2>/dev/null; then
    cat <<'EOF'
freshly-painted Egyptian limestone relief, vivid pigments — lapis blue, malachite green, ochre, gold leaf — as if the carvers laid down their brushes yesterday
brilliantly painted Mesopotamian fresco on plastered mud-brick walls, bold geometric borders in red, blue, and white, figures in profile
glazed terracotta cylinder seal impression rolled out on wet clay, ochre and cream tones, fine miniature figures
gold and lapis votive statuette of a god or king, lit from above, against a deep black void, polished metal sheen
painted Egyptian tomb-wall scene, freshly applied pigment, figures in strict profile, hieroglyphs above and below, every colour vivid
glazed-brick Mesopotamian palace panel, blue field with white striding lions and rosettes, just-fired and gleaming
EOF
  elif [ "$year" -lt 500 ] 2>/dev/null; then
    cat <<'EOF'
classical Greek red-figure pottery scene, terracotta and black, intricate fine-line drawing
Roman fresco from a freshly-plastered villa wall, rich red ochre, deep blacks, vivid figures and architectural details
Hellenistic marble statue, freshly carved white marble against a soft neutral backdrop, dramatic chiaroscuro
Byzantine mosaic, golden tesserae background, robed figures in jewel tones
late Roman wall painting in vibrant earth tones, garden or banquet scene
painted Greek terracotta votive figure, brightly coloured at the moment of dedication
EOF
  elif [ "$year" -lt 1400 ] 2>/dev/null; then
    cat <<'EOF'
medieval illuminated manuscript page, freshly painted gold leaf and lapis blue on parchment, marginal grotesques
Norman tapestry panel, embroidered figures in earthy wool tones, just off the loom
stained-glass window scene, jewel tones and lead lines, sunlight streaming through
ivory carved diptych, white relief on dark background, intricate figures
Romanesque cathedral fresco, freshly painted, bold colours and elongated figures
heraldic banner, freshly dyed in saturated colours, rampant lions and crosses
EOF
  elif [ "$year" -lt 1800 ] 2>/dev/null; then
    cat <<'EOF'
Renaissance oil painting, chiaroscuro lighting, rich figures, freshly varnished
Renaissance woodcut engraving, fine cross-hatching on cream paper, just pulled from the press
copper etching, fine line work, deep blacks, sharp impression
Dutch golden-age genre scene, oil on panel, candlelit interior
hand-coloured engraved map page, vivid borders and cartouches
Baroque fresco ceiling fragment, swirling figures and clouds, freshly painted
EOF
  elif [ "$year" -lt 1900 ] 2>/dev/null; then
    cat <<'EOF'
19th-century lithograph, soft tonal gradient, single-page editorial scene
sepia daguerreotype, formal portrait or scene, soft focus
hand-coloured engraving, vivid hues, scientific or topographical subject
political cartoon in pen and ink, vintage newspaper style
chromolithograph poster, bold flat colours, dramatic typography excluded
EOF
  else
    cat <<'EOF'
black-and-white press photograph, gritty mid-century newsprint feel, candid moment
modern editorial illustration, pen and ink with crosshatched shading
documentary colour photograph, candid moment, bold composition
1950s editorial cartoon in heavy black ink
modern news photo with grainy halftone reproduction
contemporary photojournalism — sharp focus, natural light, single subject in motion
EOF
  fi
}

# ---------------------------------------------------------------------------
# Look up the Gemini API key (env > .env > save dir file). Empty stdout
# if no key found.
# ---------------------------------------------------------------------------
_gemini_api_key() {
  local k="${GEMINI_API_KEY:-}"
  if [ -z "$k" ] && [ -f "$SCRIPT_DIR/.env" ]; then
    k=$(grep '^GEMINI_API_KEY=' "$SCRIPT_DIR/.env" | head -1 | sed 's/^GEMINI_API_KEY=//' | tr -d '[:space:]"'"'")
  fi
  if [ -z "$k" ] && [ -f "$SAVE_DIR/gemini_api_key" ]; then
    k=$(cat "$SAVE_DIR/gemini_api_key" | tr -d '[:space:]')
  fi
  echo "$k"
}

# ---------------------------------------------------------------------------
# Single Gemini image call. $1 = full prompt string, $2 = output filename
# (no path). Writes to $SAVE_DIR/$2 + symlinks into webroot. Returns 0 on
# success (filename echoed to stdout), 1 on failure (error to stderr).
# ---------------------------------------------------------------------------
_gemini_generate_one() {
  local prompt="$1" out_basename="$2" aspect="${3:-16:9}"
  local api_key
  api_key=$(_gemini_api_key)
  [ -z "$api_key" ] && { echo "[gazette] No Gemini API key" >&2; return 1; }

  local request_body response image_data
  request_body=$(jq -n --arg prompt "$prompt" --arg ar "$aspect" '{
    contents: [{ parts: [{text: $prompt}] }],
    generationConfig: {
      responseModalities: ["Text", "Image"],
      temperature: 0.8,
      imageConfig: { imageSize: "1K", aspectRatio: $ar }
    }
  }')
  response=$(curl -s --max-time 60 \
    -H "x-goog-api-key: $api_key" \
    -H "Content-Type: application/json" \
    -d "$request_body" \
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-image-preview:generateContent")
  image_data=$(echo "$response" | jq -r '.candidates[0].content.parts[] | select(.inlineData) | .inlineData.data // empty' 2>/dev/null | head -1)

  if [ -z "$image_data" ]; then
    echo "[gazette] Gemini failed for $out_basename" >&2
    echo "$response" | jq -r '.error.message // empty' >&2 2>/dev/null
    return 1
  fi
  echo "$image_data" | base64 -d > "$SAVE_DIR/$out_basename"
  ln -sf "$SAVE_DIR/$out_basename" "$WEBROOT/$out_basename" 2>/dev/null || true
  echo "$out_basename"
}

# ---------------------------------------------------------------------------
# v2 multi-image driver. Reads `entry.images[]`, generates each image in
# parallel (cap of 2 concurrent), writes the resulting filenames back into
# the entry as `images[i].file`. Failures are non-fatal — a missing file
# just renders as the typeset "(Photo unavailable)" placeholder.
#
# Args:
#   $1  the entry JSON
#   $2  target turn (for filenames)
#   $3  game year (for art-style preamble)
# Echoes the (possibly mutated) entry JSON to stdout.
# ---------------------------------------------------------------------------
generate_images_for_entry() {
  local entry="$1" turn="$2" year="$3"
  local n_images
  n_images=$(echo "$entry" | jq '.images // [] | length')
  [ "$n_images" -eq 0 ] && { echo "$entry"; return 0; }
  echo "[gazette] Generating $n_images image(s) via Gemini (max 2 concurrent)..." >&2
  local _t0_img
  _t0_img=$(date +%s)

  # Cache the era's full style pool once; we'll pick a different one
  # per image so a single edition shows visual variety (a fresco, a
  # statuette, and a painted relief — not three identical tablets).
  local style_pool
  style_pool=$(_art_styles_for_year "$year")

  # Build the per-image prompt + dispatch up to 2 concurrent jobs.
  local tmpdir
  tmpdir=$(mktemp -d)
  local i=0 max_concurrent=2 running=0
  while [ "$i" -lt "$n_images" ]; do
    local img id prompt out_basename art_style aspect aspect_word
    img=$(echo "$entry" | jq -c ".images[$i]")
    id=$(echo "$img" | jq -r '.id')
    art_style=$(printf '%s\n' "$style_pool" | shuf -n 1)
    # Per-image aspect ratio. AI can request "wide" (16:9, default — best
    # for hero/lead images), "tall" (3:4 — for inline-floated portraits),
    # or "square" (1:1 — for icon-like images). Defaults to wide so
    # images don't dominate the page vertically the way 1:1 squares do.
    aspect=$(echo "$img" | jq -r '.aspect // "wide"')
    case "$aspect" in
      tall)   aspect="3:4";   aspect_word="tall portrait" ;;
      square) aspect="1:1";   aspect_word="square" ;;
      wide|*) aspect="16:9";  aspect_word="wide landscape" ;;
    esac
    prompt="A single newspaper editorial illustration. Medium: ${art_style}. Scene: $(echo "$img" | jq -r '.prompt'). Focus on the specific subjects and action — this is not a generic era scene, it is an image of this exact moment in this exact place. The work is being created NOW (in the era depicted), not viewed centuries later — colours are vivid and fresh. No text, letters, or words anywhere in the image. ${aspect_word^} ${aspect} aspect ratio, detailed."
    out_basename="gazette-${turn}-${id}.png"
    (
      result=$(_gemini_generate_one "$prompt" "$out_basename" "$aspect" 2>>"$tmpdir/errors.log") && \
        echo "$id $result" > "$tmpdir/$id.ok"
    ) &
    running=$((running + 1))
    i=$((i + 1))
    if [ "$running" -ge "$max_concurrent" ]; then
      wait -n 2>/dev/null || wait
      running=$((running - 1))
    fi
  done
  wait

  # Merge results back into entry.images[].file.
  local id basename
  for okfile in "$tmpdir"/*.ok; do
    [ -f "$okfile" ] || continue
    id=$(awk '{print $1}' "$okfile")
    basename=$(awk '{print $2}' "$okfile")
    entry=$(echo "$entry" | jq --arg id "$id" --arg f "$basename" '
      .images = (.images | map(if .id == $id then .file = $f else . end))
    ')
  done

  if [ -s "$tmpdir/errors.log" ]; then
    cat "$tmpdir/errors.log" >&2
  fi
  local _ok_count
  _ok_count=$(ls "$tmpdir"/*.ok 2>/dev/null | wc -l | tr -d ' ')
  rm -rf "$tmpdir"
  echo "[gazette] Image generation done in $(($(date +%s) - _t0_img))s ($_ok_count/$n_images succeeded)" >&2
  echo "$entry"
}

# ---------------------------------------------------------------------------
# v1 single-illustration helper. Kept for v1-style fallback when the model
# returns the legacy schema. Calls _gemini_generate_one under the hood.
# ---------------------------------------------------------------------------
generate_illustration() {
  local headline="$1" year="$2" target_turn="$3" front_page_text="$4"
  local art_credit="$5" illustration_desc="$6"

  local art_style
  art_style=$(_art_styles_for_year "$year" | shuf -n 1)

  local artist_style=""
  if [ -n "$art_credit" ]; then
    artist_style="In the style described by: ${art_credit}. "
  fi
  local scene_desc
  if [ -n "$illustration_desc" ]; then
    scene_desc="Scene to depict (one specific moment from this news story): ${illustration_desc}. Headline for context: \"${headline}\"."
  else
    local clean_text
    clean_text=$(echo "$front_page_text" | sed 's/<[^>]*>//g' | head -c 300)
    scene_desc="Headline: \"${headline}\". Scene context: ${clean_text}"
  fi

  local prompt="A single newspaper editorial illustration depicting the scene below. ${artist_style}Style: ${art_style}. ${scene_desc} Focus on the specific subjects and action — this is not a generic era scene, it is an image of this exact moment. No text, letters, or words anywhere in the image. Square format, detailed."

  echo "[gazette] Generating illustration for turn $target_turn..." >&2
  _gemini_generate_one "$prompt" "gazette-${target_turn}.png"
}

# ---------------------------------------------------------------------------
# Validate the history.json entry for the target turn looks sane before we
# generate an edition. A partial save read can write an entry with far fewer
# players than reality (see turn 41: 2 players instead of 16), producing a
# chronicle that falsely announces catastrophic events.
#
# Strategy:
#   - Check player count for target vs. previous turn.
#   - If target has 0 players, or <50% of prev turn's count, treat as corrupt.
#   - Ask generate_status_json.sh --rebuild-turn=N to rebuild from the save.
#   - Retry up to 5 times, sleeping between attempts to let any in-flight save
#     finish.
#   - If still bad, return failure so the caller can skip this edition.
# ---------------------------------------------------------------------------
validate_turn_history() {
  local target="$1"
  local max_attempts=5
  local attempt=1
  while [ "$attempt" -le "$max_attempts" ]; do
    if [ ! -f "$HISTORY_FILE" ]; then
      echo "[gazette] history.json missing (attempt $attempt/$max_attempts)" >&2
      sleep 10
      attempt=$((attempt + 1))
      continue
    fi
    local cur_n prev_n
    cur_n=$(jq --argjson t "$target" '[.[] | select(.turn == $t)] | .[0].players // {} | keys | length' "$HISTORY_FILE" 2>/dev/null || echo 0)
    prev_n=$(jq --argjson t "$((target - 1))" '[.[] | select(.turn == $t)] | .[0].players // {} | keys | length' "$HISTORY_FILE" 2>/dev/null || echo 0)
    # Sane if target has >=1 player AND (no prev turn, or target >= half of prev).
    if [ "$cur_n" -gt 0 ] 2>/dev/null && { [ "$prev_n" -eq 0 ] 2>/dev/null || [ "$((cur_n * 2))" -ge "$prev_n" ] 2>/dev/null; }; then
      return 0
    fi
    echo "[gazette] Turn $target history looks corrupt: $cur_n players vs. $prev_n in prev turn (attempt $attempt/$max_attempts)" >&2
    local turn_save="$SAVE_DIR/lt-game-${target}.sav.gz"
    if [ -f "$turn_save" ]; then
      "$SCRIPT_DIR/generate_status_json.sh" --rebuild-turn="$target" >> "$SAVE_DIR/status-generator.log" 2>&1 || true
    else
      echo "[gazette] Save file $turn_save not present yet" >&2
    fi
    sleep 10
    attempt=$((attempt + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# Process a single turn
# ---------------------------------------------------------------------------
process_turn() {
  local target_turn="$1"
  local _pt
  _pt=$(plog_begin gazette "process_turn ${target_turn}")

  # Skip if already generated
  local exists
  exists=$(echo "$GAZETTE_JSON" | jq --argjson t "$target_turn" '[.[] | select(.turn == $t)] | length')
  if [ "$exists" -gt 0 ] && [ "$REBUILD" = "false" ]; then
    echo "[gazette] Turn $target_turn already exists, skipping"
    plog_end gazette "process_turn ${target_turn} (already exists)" "$_pt"
    return 0
  fi

  echo "[gazette] Generating gazette for turn $target_turn..."
  local _bc context
  _bc=$(plog_begin gazette "build_turn_context ${target_turn}")
  context=$(build_turn_context "$target_turn")
  plog_end gazette "build_turn_context ${target_turn}" "$_bc"
  [ "$context" = "{}" ] && { echo "[gazette] No history data for turn $target_turn"; plog_end gazette "process_turn ${target_turn} (no history)" "$_pt"; return 0; }

  # Get previous issue for continuity
  local prev_issue
  prev_issue=$(echo "$GAZETTE_JSON" | jq --argjson t "$((target_turn - 1))" '[.[] | select(.turn == $t)] | .[0] // null')

  # Get recent headlines so the AI knows what's already been covered
  local recent_headlines
  recent_headlines=$(echo "$GAZETTE_JSON" | jq --argjson t "$target_turn" \
    '[.[] | select(.turn < $t) | {turn: .turn, year_display: .year_display, headline: .headline}] | sort_by(-.turn) | .[:5]')

  # Pull every crossword word (from any past edition) so the AI never
  # repeats — crosswords get stale fast when the same answers come up
  # turn after turn. We collect uniquely from the v2 schema's
  # pages[].sections[].entries[].word path AND the legacy v1 path where
  # crosswords were inlined as section bodies.
  local recent_crossword_words
  recent_crossword_words=$(echo "$GAZETTE_JSON" | jq --argjson t "$target_turn" '
    [
      .[] | select(.turn < $t) |
      (.pages // []) | .[] | (.sections // []) | .[] |
      select(.kind == "puzzle" and .type == "crossword") |
      (.entries // []) | .[] | .word
    ] | map(ascii_upcase) | unique | sort
  ')

  # Inject into context
  context=$(echo "$context" | jq \
    --argjson rh "$recent_headlines" \
    --argjson rcw "$recent_crossword_words" \
    '. + {recent_headlines: $rh, recent_crossword_words: $rcw}')

  local entry="" attempt=1 max_attempts=3
  while [ "$attempt" -le "$max_attempts" ]; do
    local _ga
    _ga=$(plog_begin gazette "generate_entry attempt ${attempt}/${max_attempts} (turn ${target_turn}, provider=${GAZETTE_PROVIDER})")
    if entry=$(generate_entry "$context" "$prev_issue"); then
      plog_end gazette "generate_entry attempt ${attempt}/${max_attempts} OK" "$_ga"
      break
    fi
    plog_end gazette "generate_entry attempt ${attempt}/${max_attempts} FAILED" "$_ga"
    entry=""
    if [ "$attempt" -lt "$max_attempts" ]; then
      local backoff=$((attempt * 5))
      echo "[gazette] generate_entry failed for turn $target_turn (attempt $attempt/$max_attempts), retrying in ${backoff}s..." >&2
      plog gazette "sleeping ${backoff}s before retry"
      sleep "$backoff"
    fi
    attempt=$((attempt + 1))
  done
  if [ -z "$entry" ]; then
    echo "[gazette] generate_entry failed for turn $target_turn after $max_attempts attempts" >&2
    plog gazette "ABORT: all ${max_attempts} attempts failed for turn ${target_turn}"
    return 1
  fi

  local year
  year=$(echo "$context" | jq -r '.year')
  local year_display
  year_display=$(echo "$context" | jq -r '.year_display')

  # Determine schema. v2 → multi-image driver; v1 fallback → single
  # illustration via the legacy helper.
  local schema_version
  schema_version=$(echo "$entry" | jq -r '.schema_version // 1')

  if [ "$schema_version" = "2" ]; then
    local _ig
    _ig=$(plog_begin gazette "generate_images_for_entry ${target_turn} (v2)")
    entry=$(generate_images_for_entry "$entry" "$target_turn" "$year")
    plog_end gazette "generate_images_for_entry ${target_turn}" "$_ig"
  else
    local illustration=""
    local headline fp_content ill_credit ill_desc
    headline=$(echo "$entry" | jq -r '.headline')
    fp_content=$(echo "$entry" | jq -r '.sections.front_page.content // .sections.front_page // ""')
    ill_credit=$(echo "$entry" | jq -r '.illustration_caption.credit // ""')
    ill_desc=$(echo "$entry" | jq -r '.illustration_caption.description // ""')
    local _ill
    _ill=$(plog_begin gazette "generate_illustration ${target_turn}")
    illustration=$(generate_illustration "$headline" "$year" "$target_turn" "$fp_content" "$ill_credit" "$ill_desc") || true
    plog_end gazette "generate_illustration ${target_turn} (out=${illustration:-none})" "$_ill"
    # Stash the filename onto the entry so the v1 jq merge below can pick it up.
    entry=$(echo "$entry" | jq --arg img "$illustration" '. + {_v1_illustration: $img}')
  fi

  # Remove existing entry for this turn if rebuilding
  GAZETTE_JSON=$(echo "$GAZETTE_JSON" | jq --argjson t "$target_turn" '[.[] | select(.turn != $t)]')

  # Merge entry into gazette.json. v2 carries `pages`, `images`, etc;
  # v1 carries `sections`, `opinion`, `letters`, `ads`, `corrections`,
  # `illustration*`. The jq below preserves whichever set the AI returned.
  local _tmpentry=$(mktemp)
  echo "$entry" > "$_tmpentry"
  GAZETTE_JSON=$(echo "$GAZETTE_JSON" | jq --argjson t "$target_turn" --argjson y "$year" \
    --arg yd "$year_display" --slurpfile entry "$_tmpentry" \
    '$entry[0] as $entry |
     # Common envelope fields the renderer relies on for masthead + sort.
     ($entry + {turn: $t, year: $y, year_display: $yd}) as $with_meta |
     # v1: stash the legacy illustration filename + caption alongside.
     (if ($entry.schema_version // 1) == 2 then
        $with_meta
      else
        $with_meta + {
          illustration: (if ($entry._v1_illustration // "") != "" then $entry._v1_illustration else null end),
          illustration_caption: ($entry.illustration_caption // null)
        } | del(._v1_illustration)
      end) as $final |
     . + [$final] | sort_by(.turn)')
  rm -f "$_tmpentry"

  # Save after each entry
  echo "$GAZETTE_JSON" > "$GAZETTE_FILE.tmp"
  mv "$GAZETTE_FILE.tmp" "$GAZETTE_FILE"
  ln -sf "$GAZETTE_FILE" "$WEBROOT/gazette.json"
  plog gazette "wrote ${GAZETTE_FILE} ($(stat -c %s "$GAZETTE_FILE" 2>/dev/null || echo ?)B)"

  # Mark unpublished player messages as used in this edition
  local DB_PATH="${DB_PATH:-/data/saves/freeciv.sqlite}"
  if [ -f "$DB_PATH" ]; then
    sqlite3 "$DB_PATH" "UPDATE editor_messages SET published=$target_turn WHERE role='player' AND published=0;" 2>/dev/null || true
    plog gazette "stamped player messages as published=${target_turn}"
  fi
  plog_end gazette "process_turn ${target_turn}" "$_pt"

  echo "[gazette] Generated: $(echo "$entry" | jq -r '.headline')"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
plog gazette "invoked args=$* provider=${GAZETTE_PROVIDER}"

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
  if ! validate_turn_history "$PREV_TURN"; then
    echo "[gazette] Skipping edition for turn $PREV_TURN — history entry still looks corrupt after retries"
    exit 1
  fi
  process_turn "$PREV_TURN"
fi

echo "[gazette] Done"
