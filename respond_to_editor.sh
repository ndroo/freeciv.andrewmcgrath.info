#!/bin/bash
# =============================================================================
# Responds to player messages sent to The Civ Chronicle editor.
# Runs hourly via cron. Also proactively reaches out to 1-2 interesting
# players per turn to solicit comment.
#
# Features:
#   - Replies to pending player messages with full conversation context
#   - Sends email notification when editor replies
#   - Proactive outreach: once per turn, contacts 1-2 players for comment
#   - Context includes: conversation history, last 2 gazette issues, game state
#
# Usage: ./respond_to_editor.sh [--outreach]
#   --outreach: also run proactive outreach (called on turn change)
# Env: ANTHROPIC_API_KEY or OPENAI_API_KEY, SES_SMTP_*
# =============================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib_log.sh"
_editor_started=$(date +%s)
plog editor "BEGIN run args=$* (pid=$$)"
trap '_rc=$?; plog editor "END run rc=${_rc} ($(( $(date +%s) - _editor_started ))s)"' EXIT
SAVE_DIR="${SAVE_DIR:-/data/saves}"
DB_PATH="${DB_PATH:-$SAVE_DIR/freeciv.sqlite}"
WEBROOT="${WEBROOT:-/opt/freeciv/www}"
STATUS_FILE="$WEBROOT/status.json"
HISTORY_FILE="$SAVE_DIR/history.json"
DIPLOMACY_FILE="$SAVE_DIR/diplomacy.json"
GAZETTE_FILE="$SAVE_DIR/gazette.json"

# Email config
SES_SMTP_USER="${SES_SMTP_USER:-}"
SES_SMTP_PASS="${SES_SMTP_PASS:-}"
SES_SMTP_HOST="${SES_SMTP_HOST:-email-smtp.us-east-1.amazonaws.com}"
FROM_EMAIL="${FROM_EMAIL:-freeciv@andrewmcgrath.info}"
SERVER_HOST="${SERVER_HOST:-freeciv.andrewmcgrath.info}"

# Check email enabled
EMAIL_ENABLED="true"
if [ -f "$SCRIPT_DIR/email_enabled.settings" ]; then
  EMAIL_ENABLED=$(cat "$SCRIPT_DIR/email_enabled.settings" | tr -d '[:space:]')
fi

# Parse args
# Usage: ./respond_to_editor.sh [--outreach] [player1 player2 ...]
#   --outreach: run proactive outreach (AI picks players, or use specified list)
#   player names after --outreach override the AI picker
DO_OUTREACH=false
OUTREACH_PLAYERS=""
for arg in "$@"; do
  case "$arg" in
    --outreach) DO_OUTREACH=true ;;
    -*) ;;
    *) [ "$DO_OUTREACH" = "true" ] && OUTREACH_PLAYERS="$OUTREACH_PLAYERS $arg" ;;
  esac
done

# Load .env if present
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  . "$SCRIPT_DIR/.env" 2>/dev/null || true
  set +a
fi

# --- Load provider + API keys ---
GAZETTE_PROVIDER="${GAZETTE_PROVIDER:-}"
if [ -z "$GAZETTE_PROVIDER" ] && [ -f "$SAVE_DIR/gazette_provider" ]; then
  GAZETTE_PROVIDER=$(cat "$SAVE_DIR/gazette_provider" | tr -d '[:space:]')
fi
GAZETTE_PROVIDER="${GAZETTE_PROVIDER:-openai}"

OPENAI_API_KEY="${OPENAI_API_KEY:-}"
if [ -z "$OPENAI_API_KEY" ] && [ -f "$SAVE_DIR/openai_api_key" ]; then
  OPENAI_API_KEY=$(cat "$SAVE_DIR/openai_api_key" | tr -d '[:space:]')
fi

ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
if [ -z "$ANTHROPIC_API_KEY" ] && [ -f "$SAVE_DIR/anthropic_api_key" ]; then
  ANTHROPIC_API_KEY=$(cat "$SAVE_DIR/anthropic_api_key" | tr -d '[:space:]')
fi

if [ "$GAZETTE_PROVIDER" = "anthropic" ] && [ -z "$ANTHROPIC_API_KEY" ]; then
  GAZETTE_PROVIDER="openai"
fi
if [ "$GAZETTE_PROVIDER" = "openai" ] && [ -z "$OPENAI_API_KEY" ]; then
  if [ -n "$ANTHROPIC_API_KEY" ]; then
    GAZETTE_PROVIDER="anthropic"
  else
    echo "[editor] No API key found, skipping"
    exit 0
  fi
fi

# --- Ensure tables exist ---
sqlite3 "$DB_PATH" "CREATE TABLE IF NOT EXISTS editor_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  player_name VARCHAR(48) NOT NULL,
  role VARCHAR(10) NOT NULL,
  content TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  turn INTEGER DEFAULT 0,
  published INTEGER DEFAULT 0
);" 2>/dev/null

# --- Get game context ---
YEAR_DISPLAY="unknown"
TURN=0
GAME_CONTEXT=""
if [ -f "$STATUS_FILE" ]; then
  TURN=$(jq -r '.game.turn // 0' "$STATUS_FILE" 2>/dev/null)
  YEAR_DISPLAY=$(jq -r '.game.year_display // "unknown"' "$STATUS_FILE" 2>/dev/null)
  # Build a concise game state summary for the editor's context
  GAME_CONTEXT=$(jq -r '
    "Current game state (Turn \(.game.turn), \(.game.year_display)):\n" +
    "Players: " + ([.players[] | "\(.name) (\(.nation), \(.government // "unknown"), score \(.score // 0), \(.cities // 0) cities, \(.units // 0) units)"] | join("; ")) + "\n" +
    "Rankings: " + ([.players | sort_by(-.score)[:5][] | "\(.name): \(.score)"] | join(", "))
  ' "$STATUS_FILE" 2>/dev/null || true)
fi

# Get recent diplomacy events
DIPLOMACY_CONTEXT=""
if [ -f "$DIPLOMACY_FILE" ]; then
  DIPLOMACY_CONTEXT=$(jq -r '
    "Active wars: " + (if (.current | map(select(.status=="War")) | length) > 0 then ([.current[] | select(.status=="War") | .players | join(" vs ")] | join(", ")) else "none" end) + "\n" +
    "Active alliances: " + (if (.current | map(select(.status=="Alliance")) | length) > 0 then ([.current[] | select(.status=="Alliance") | .players | join(" & ")] | join(", ")) else "none" end) + "\n" +
    "Peace treaties: " + (if (.current | map(select(.status=="Peace")) | length) > 0 then ([.current[] | select(.status=="Peace") | .players | join(" & ")] | join(", ")) else "none" end) + "\n" +
    "Armistices: " + (if (.current | map(select(.status=="Armistice")) | length) > 0 then ([.current[] | select(.status=="Armistice") | .players | join(" & ")] | join(", ")) else "none" end) + "\n" +
    "All relationships: " + ([.current[] | "\(.players | join(" & ")): \(.status)"] | join(", ")) + "\n" +
    "Recent events: " + ([.events[-5:][] | "\(.players | join(" & ")): \(.from // "none") -> \(.to)"] | join("; "))
  ' "$DIPLOMACY_FILE" 2>/dev/null || true)
fi

# Get last 2 gazette headlines for context
GAZETTE_CONTEXT=""
if [ -f "$GAZETTE_FILE" ]; then
  # Pull a teaser of the last 2 issues. Handles v1 (sections.front_page)
  # and v2 (pages[].sections[] with kind=="lead") by checking whichever
  # is present — keeps the editor responsive across schema versions.
  GAZETTE_CONTEXT=$(jq -r '
    def front:
      if .sections then (.sections.front_page.content // .sections.front_page // "")
      elif .pages then ([.pages[].sections[] | select(.kind == "lead")] | .[0].content // "")
      else "" end;
    [.[-2:][] | "Turn \(.turn) (\(.year_display)): \(.headline)\nFront page: \(front | gsub("<[^>]*>"; "") | .[0:300])"] | join("\n\n")
  ' "$GAZETTE_FILE" 2>/dev/null || true)
fi

NOW=$(date +%s)

# ---------------------------------------------------------------------------
# Build system prompt with full context
# ---------------------------------------------------------------------------
build_system_prompt() {
  local player="$1"
  local player_nation="$2"
  local player_gov="$3"
  local mode="${4:-reply}"  # "reply" or "outreach"

  local player_detail=""
  if [ -f "$STATUS_FILE" ]; then
    player_detail=$(jq -r --arg p "$player" '
      .players[] | select(.name==$p) |
      "Score: \(.score // "?"), Cities: \(.cities // "?"), Units: \(.units // "?"), Rank: \(.rank // "?")"
    ' "$STATUS_FILE" 2>/dev/null || true)
  fi

  local prompt="You are the editor-in-chief of The Civ Chronicle, a newspaper covering a Freeciv multiplayer game."

  if [ "$mode" = "outreach" ]; then
    prompt="$prompt You are reaching out to ${player}, leader of the ${player_nation:-unknown nation}${player_gov:+ ($player_gov)}, to solicit a comment or statement for an upcoming issue."
  else
    prompt="$prompt You are responding to correspondence from ${player}, leader of the ${player_nation:-unknown nation}${player_gov:+ ($player_gov)}."
  fi

  prompt="$prompt

The current game year is ${YEAR_DISPLAY}. Match your writing style to this era:
- Ancient (4000-1000 BC): Formal chronicle tone, mythic references
- Classical (1000 BC-500 AD): Herodotus-style, authoritative
- Medieval (500-1400 AD): Court scribe, formal but gossipy
- Renaissance (1400-1800): Broadsheet editor, flowery but pointed
- Modern (1800+): Modern newspaper editor, witty and professional

You are a CHARACTER — the editor of a newspaper, not an AI assistant. Stay in character at all times.

## About ${player}
Nation: ${player_nation:-unknown}
Government: ${player_gov:-unknown}
${player_detail}

## World state
${GAME_CONTEXT}

## Diplomacy
${DIPLOMACY_CONTEXT}

## Recent Chronicle headlines
${GAZETTE_CONTEXT}

## CONFIDENTIAL — Other correspondence (DO NOT REVEAL)
You have received private correspondence from other world leaders. This gives you insider knowledge that informs your editorial judgment, but you MUST NEVER:
- Quote or paraphrase another leader's private messages to this player
- Reveal who has been writing to the editor
- Say things like \"another leader told me\" or \"I've heard from sources close to X\"
- Confirm or deny whether any specific leader has contacted the Chronicle

You MAY use this knowledge subtly:
- Ask pointed questions that happen to touch on things you've learned
- Express editorial opinions that are informed by what you know
- Say things like \"rumors in the capital suggest...\" or \"this editor has reason to believe...\"
- Challenge claims you know to be misleading based on other accounts

Think of it like a real newspaper editor who has multiple sources but protects them absolutely.

$(sqlite3 "$DB_PATH" "SELECT player_name, role, content FROM editor_messages WHERE player_name != '$player' ORDER BY created_at DESC LIMIT 30;" 2>/dev/null | awk -F'|' '{printf "%s (%s): %s\n", $1, $2, $3}')"

  if [ "$mode" = "outreach" ]; then
    prompt="$prompt

You are initiating contact — writing a letter to this leader to ask for comment on something specific and newsworthy. Pick ONE angle based on the game state:
- If they're involved in a war or tension, ask about their military strategy or peace terms
- If they recently built a wonder or are leading in score, ask about their ambitions
- If they're an underdog, ask about their survival strategy
- If there's a diplomatic event involving them, ask for their official statement
- If their government type is unusual, ask about their political philosophy

Be specific. Reference real events from the game data. Ask a pointed question that would make a great headline if they answer it.

Keep it SHORT — 2-3 sentences. You're a busy editor sending a quick note, not writing a feature."
  else
    prompt="$prompt

You may:
- Acknowledge their submission and thank them for writing
- Ask follow-up questions to get more detail for a story
- React to their news with editorial interest or skepticism
- Promise to investigate or assign a reporter
- Share relevant gossip or observations from other parts of the game world
- Reference what's happening to their nation specifically based on the game data

Keep responses SHORT — 2-4 sentences. You're a busy editor dashing off a reply.

Note: anything the player tells you may be quoted or referenced in the next edition of the newspaper. All correspondence with the editor is on the record."
  fi

  printf '%s' "$prompt"
}

# ---------------------------------------------------------------------------
# Call AI API
# ---------------------------------------------------------------------------
call_ai() {
  local system_prompt="$1"
  local messages_json="$2"
  local max_tokens="${3:-300}"
  local response_text=""

  if [ "$GAZETTE_PROVIDER" = "anthropic" ]; then
    local request
    request=$(jq -n \
      --arg system "$system_prompt" \
      --argjson messages "$messages_json" \
      --argjson max "$max_tokens" \
      '{model: "claude-opus-4-6", max_tokens: $max, system: $system, messages: $messages, temperature: 0.8}')

    local response
    response=$(curl -s --max-time 60 \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "Content-Type: application/json" \
      -d "$request" \
      "https://api.anthropic.com/v1/messages")

    response_text=$(echo "$response" | jq -r '.content[0].text // empty')
  else
    local request
    request=$(jq -n \
      --arg system "$system_prompt" \
      --argjson messages "$messages_json" \
      --argjson max "$max_tokens" \
      '{model: "gpt-5.4", messages: ([{role: "system", content: $system}] + $messages), temperature: 0.8, max_completion_tokens: $max}')

    local response
    response=$(curl -s --max-time 60 \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$request" \
      "https://api.openai.com/v1/chat/completions")

    response_text=$(echo "$response" | jq -r '.choices[0].message.content // empty')
  fi

  printf '%s' "$response_text"
}

# ---------------------------------------------------------------------------
# Send email notification to player
# ---------------------------------------------------------------------------
send_editor_email() {
  local player="$1"
  local editor_reply="$2"
  local mode="${3:-reply}"  # "reply" or "outreach"

  # Check if emails are enabled
  [ "$EMAIL_ENABLED" != "true" ] && return 0
  [ -z "$SES_SMTP_USER" ] && return 0

  # Get player email
  local email
  email=$(sqlite3 "$DB_PATH" "SELECT email FROM fcdb_auth WHERE LOWER(name)=LOWER('$player') AND email IS NOT NULL AND email != '';" 2>/dev/null)
  [ -z "$email" ] && { echo "[editor] No email for $player"; return 0; }

  # Convert markdown to HTML: **bold**, *italic*, newlines to <br>
  local html_reply
  html_reply=$(printf '%s' "$editor_reply" | \
    sed 's/\*\*\([^*]*\)\*\*/<strong>\1<\/strong>/g' | \
    sed 's/\*\([^*]*\)\*/<em>\1<\/em>/g' | \
    sed 's/$/<br>/g')

  # Different subject and intro for outreach vs reply
  local subject intro_text button_text
  if [ "$mode" = "outreach" ]; then
    subject="The Civ Chronicle — The Editor requests your comment"
    intro_text="The editor of The Civ Chronicle is seeking your comment for an upcoming issue:"
    button_text="Respond to the Editor"
  else
    subject="The Civ Chronicle — The Editor has replied"
    intro_text="The editor has responded to your message:"
    button_text="Continue the Conversation"
  fi

  local email_msg
  email_msg=$(cat <<EMAILEOF
From: The Civ Chronicle <$FROM_EMAIL>
To: $email
Subject: $subject
MIME-Version: 1.0
Content-Type: text/html; charset="UTF-8"

<!DOCTYPE html>
<html><body style="margin:0;padding:0;background:#1a1a1a;font-family:Georgia,'Times New Roman',serif;">
<div style="max-width:560px;margin:0 auto;background:#f5f0e6;border:1px solid #d5d0c5;">

  <div style="text-align:center;padding:20px 24px 14px;border-bottom:3px double #1a1a1a;">
    <div style="font-size:28px;font-weight:900;color:#1a1a1a;letter-spacing:1px;">The Civ Chronicle</div>
    <div style="font-size:10px;color:#888;text-transform:uppercase;letter-spacing:3px;margin-top:4px;">Correspondence Desk</div>
  </div>

  <div style="padding:20px 24px;">
    <p style="font-size:13px;color:#1a1a1a;margin:0 0 16px;">Dear ${player},</p>
    <p style="font-size:12px;color:#666;margin:0 0 8px;font-style:italic;">${intro_text}</p>

    <div style="background:#fff;border:1px solid #ccc;padding:14px 18px;margin:12px 0;font-size:13px;line-height:1.7;color:#2a2a2a;font-style:italic;">
      ${html_reply}
    </div>

    <div style="text-align:center;margin:20px 0;">
      <a href="https://${SERVER_HOST}/editor.html" style="display:inline-block;background:#1a1a1a;color:#f5f0e6;text-decoration:none;padding:10px 28px;font-size:13px;font-family:Georgia,serif;letter-spacing:1px;">${button_text}</a>
    </div>

    <p style="font-size:10px;color:#999;text-align:center;margin:16px 0 0;line-height:1.5;">
      You cannot reply to this email. To continue the conversation,<br>
      sign in at <a href="https://${SERVER_HOST}/editor.html" style="color:#537895;">${SERVER_HOST}</a> using your Freeciv credentials.
    </p>
  </div>

  <div style="text-align:center;padding:10px;border-top:3px double #1a1a1a;font-size:9px;color:#888;text-transform:uppercase;letter-spacing:2px;">
    All the civilization that's fit to print
  </div>

</div>
</body></html>
EMAILEOF
)

  echo "$email_msg" | curl -s --url "smtps://$SES_SMTP_HOST:465" \
    --ssl-reqd \
    --mail-from "$FROM_EMAIL" \
    --mail-rcpt "$email" \
    ${CC_EMAIL:+--mail-rcpt "$CC_EMAIL"} \
    --user "$SES_SMTP_USER:$SES_SMTP_PASS" \
    --upload-file - 2>&1

  echo "[editor] Email sent to $player ($email)"
}

# ---------------------------------------------------------------------------
# Build conversation messages array for a player
# ---------------------------------------------------------------------------
build_messages() {
  local player="$1"
  local limit="${2:-30}"

  # Use sqlite3 -json to handle multi-line content correctly
  local raw_json
  raw_json=$(sqlite3 -json "$DB_PATH" "
    SELECT role, content FROM editor_messages
    WHERE player_name='$player'
    ORDER BY created_at ASC LIMIT $limit;" 2>/dev/null)

  if [ -z "$raw_json" ] || [ "$raw_json" = "[]" ]; then
    printf '[]'
    return
  fi

  # Convert to API format: role player->user, editor->assistant
  local messages_json
  messages_json=$(echo "$raw_json" | jq -c '[.[] | {
    role: (if .role == "player" then "user" else "assistant" end),
    content: .content
  } | select(.content != null and .content != "")]')

  printf '%s' "$messages_json"
}

# ---------------------------------------------------------------------------
# Process a reply to a player and handle publish/email
# ---------------------------------------------------------------------------
process_reply() {
  local player="$1"
  local response_text="$2"

  # Strip any [PUBLISH] tags if the AI still includes them (legacy)
  response_text=$(echo "$response_text" | sed 's/\[PUBLISH\]//g' | sed '/^[[:space:]]*$/d')

  # Escape for SQLite
  local safe_response
  safe_response=$(printf '%s' "$response_text" | sed "s/'/''/g")

  # Insert editor response
  sqlite3 "$DB_PATH" "INSERT INTO editor_messages (player_name, role, content, created_at, turn)
    VALUES ('$player', 'editor', '$safe_response', $NOW, $TURN);" 2>/dev/null

  # Send email notification
  send_editor_email "$player" "$response_text"

  echo "[editor] Replied to $player: $(echo "$response_text" | head -c 80)..."
}

# ===========================================================================
# PART 1: Reply to pending messages
# ===========================================================================

PENDING=$(sqlite3 "$DB_PATH" "
  SELECT DISTINCT em.player_name FROM editor_messages em
  WHERE em.role='player'
  AND em.created_at > COALESCE(
    (SELECT MAX(em2.created_at) FROM editor_messages em2
     WHERE em2.player_name=em.player_name AND em2.role='editor'),
    0
  );" 2>/dev/null)

echo "[editor] Using provider: $GAZETTE_PROVIDER"

if [ -n "$PENDING" ]; then
  echo "[editor] Pending responses for: $(echo "$PENDING" | tr '\n' ', ')"

  for PLAYER in $PENDING; do
    echo "[editor] Processing $PLAYER..."

    PLAYER_NATION=$(jq -r --arg p "$PLAYER" '.players[] | select(.name==$p) | .nation // ""' "$STATUS_FILE" 2>/dev/null || true)
    PLAYER_GOV=$(jq -r --arg p "$PLAYER" '.players[] | select(.name==$p) | .government // ""' "$STATUS_FILE" 2>/dev/null || true)

    SYSTEM_PROMPT=$(build_system_prompt "$PLAYER" "$PLAYER_NATION" "$PLAYER_GOV" "reply")
    MESSAGES_JSON=$(build_messages "$PLAYER" 30)

    RESPONSE_TEXT=$(call_ai "$SYSTEM_PROMPT" "$MESSAGES_JSON" 2400)

    if [ -z "$RESPONSE_TEXT" ]; then
      echo "[editor] API call failed for $PLAYER"
      continue
    fi

    process_reply "$PLAYER" "$RESPONSE_TEXT"
    sleep 1
  done
else
  echo "[editor] No pending messages"
fi

# ===========================================================================
# PART 2: Proactive outreach (once per turn, 1-2 interesting players)
# ===========================================================================

if [ "$DO_OUTREACH" = "true" ] && [ -f "$STATUS_FILE" ]; then
  echo "[editor] Running proactive outreach..."

  # Check if we already did outreach this turn
  OUTREACH_DONE=$(sqlite3 "$DB_PATH" "
    SELECT COUNT(*) FROM editor_messages
    WHERE role='editor' AND turn=$TURN
    AND content LIKE '%reaching out%' OR content LIKE '%comment%' OR content LIKE '%statement%'
    AND player_name IN (
      SELECT DISTINCT player_name FROM editor_messages WHERE turn=$TURN AND role='editor'
      GROUP BY player_name
      HAVING MIN(id) = id
    );" 2>/dev/null || echo "0")

  # Simpler check: did the editor initiate any NEW conversations this turn?
  OUTREACH_INITIATED=$(sqlite3 "$DB_PATH" "
    SELECT COUNT(DISTINCT player_name) FROM editor_messages
    WHERE role='editor' AND turn=$TURN
    AND player_name NOT IN (
      SELECT DISTINCT player_name FROM editor_messages
      WHERE role='player' AND turn=$TURN
    );" 2>/dev/null || echo "0")

  if [ -n "$OUTREACH_PLAYERS" ]; then
    echo "[editor] Manual outreach to:$OUTREACH_PLAYERS"
  elif [ "${OUTREACH_INITIATED:-0}" -ge 3 ]; then
    echo "[editor] Already reached out to $OUTREACH_INITIATED players this turn, skipping"
  fi

  if [ -n "$OUTREACH_PLAYERS" ] || [ "${OUTREACH_INITIATED:-0}" -lt 3 ]; then

   if [ -n "$OUTREACH_PLAYERS" ]; then
    # Manual player list — resolve case-insensitive names against real players
    PICKS_JSON="[]"
    for manual_name in $OUTREACH_PLAYERS; do
      REAL_NAME=$(jq -r --arg p "$manual_name" '.players[] | select(.name | ascii_downcase == ($p | ascii_downcase)) | .name' "$STATUS_FILE" 2>/dev/null)
      if [ -n "$REAL_NAME" ]; then
        PICKS_JSON=$(echo "$PICKS_JSON" | jq --arg n "$REAL_NAME" '. + [{"name":$n,"reason":"Manual outreach requested"}]')
      else
        echo "[editor] Unknown player: $manual_name, skipping"
      fi
    done
   else
    # Build outreach context: who's been contacted, who hasn't, what players are saying
    RECENTLY_CONTACTED=$(sqlite3 "$DB_PATH" "
      SELECT player_name || ' (turn ' || GROUP_CONCAT(DISTINCT turn) || ')'
      FROM editor_messages WHERE role='editor' AND turn > $((TURN - 4))
      GROUP BY player_name ORDER BY MAX(turn) DESC;" 2>/dev/null | tr '\n' ', ')

    NEVER_CONTACTED=$(jq -r '.players[].name' "$STATUS_FILE" 2>/dev/null | while read -r pname; do
      has_msg=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM editor_messages WHERE player_name='$pname' OR player_name='$(echo "$pname" | tr '[:upper:]' '[:lower:]')';" 2>/dev/null || echo "0")
      [ "$has_msg" -eq 0 ] && echo "$pname"
    done | tr '\n' ', ')

    # Summarise recent player conversations so the editor can seek reactions
    RECENT_TALK=$(sqlite3 "$DB_PATH" "
      SELECT player_name || ': ' || substr(content, 1, 150)
      FROM editor_messages WHERE role='player'
      ORDER BY created_at DESC LIMIT 10;" 2>/dev/null | tr '\n' '|')
    RECENT_TALK_FORMATTED=$(echo "$RECENT_TALK" | sed 's/|/\n- /g' | sed '1s/^/- /')

    # Pick interesting players using AI
    PICK_PROMPT="You are the editor-in-chief of The Civ Chronicle. Pick 1-3 players to reach out to for the next issue. You want a DIVERSE spread of voices — not the same players every turn.

SELECTION PRIORITIES (in order):
1. Players who have NEVER been contacted — cold outreach to get new voices into the paper
2. Players referenced or discussed by OTHER players — seek their reaction/comment
3. Players at the extremes: top-ranked leaders, bottom-ranked underdogs, or those with unusual situations
4. Players involved in wars, alliances, or diplomatic shifts THIS turn
5. Players whose silence on a major event is itself newsworthy

AVOID re-contacting players the editor spoke to in the last 2-3 turns unless there is a compelling new development.

Current game state:
${GAME_CONTEXT}

Diplomacy:
${DIPLOMACY_CONTEXT}

Players the editor has contacted recently: ${RECENTLY_CONTACTED:-none}

Players the editor has NEVER contacted: ${NEVER_CONTACTED:-none}

Players already contacted THIS turn: $(sqlite3 "$DB_PATH" "SELECT DISTINCT player_name FROM editor_messages WHERE turn=$TURN AND role='editor';" 2>/dev/null | tr '\n' ', ')

Recent things players have told the editor (use these to seek reactions from the people they mention):
${RECENT_TALK_FORMATTED}

Return ONLY a JSON array of objects with player name and the reason/angle for contacting them (1-3 players). Prefer at least one player who has NEVER been contacted. Example:
[{\"name\":\"DetectiveG\",\"reason\":\"Bottom of the rankings with 1 city — how does Ecuador plan to survive?\"},{\"name\":\"Tankerjon\",\"reason\":\"Shogun told us the war was a misunderstanding — what's Rome's side of the story?\"}]
Keep reasons under 20 words. Do NOT explain outside the JSON. Output ONLY the JSON array."

    PICKS_RAW=$(call_ai "$PICK_PROMPT" '[{"role":"user","content":"Return only the JSON array of 1-3 player objects with name and reason. Keep reasons under 20 words each."}]' 300)
    # Strip markdown code fences if present
    PICKS_JSON=$(echo "$PICKS_RAW" | sed '/^```/d' | jq -c '.' 2>/dev/null || echo "[]")
   fi  # end manual vs AI picker

    # Parse picks — try structured JSON first, fall back to name extraction
    PICK_COUNT=$(echo "$PICKS_JSON" | jq 'length' 2>/dev/null || echo 0)
    if [ "$PICK_COUNT" -gt 0 ] 2>/dev/null; then
      # Structured JSON with reasons
      PICK_INDICES=$(seq 0 $((PICK_COUNT > 3 ? 2 : PICK_COUNT - 1)))
    else
      PICK_INDICES=""
    fi

    for idx in $PICK_INDICES; do
      PLAYER=$(echo "$PICKS_JSON" | jq -r ".[$idx].name // empty" 2>/dev/null)
      OUTREACH_REASON=$(echo "$PICKS_JSON" | jq -r ".[$idx].reason // empty" 2>/dev/null)

      # Fall back: if name field missing, try treating array as simple strings
      if [ -z "$PLAYER" ]; then
        PLAYER=$(echo "$PICKS_JSON" | jq -r ".[$idx] // empty" 2>/dev/null)
        OUTREACH_REASON=""
      fi
      [ -z "$PLAYER" ] && continue

      # Verify this is a real player (case-insensitive match, resolve to canonical name)
      PLAYER=$(jq -r --arg p "$PLAYER" '.players[] | select(.name | ascii_downcase == ($p | ascii_downcase)) | .name' "$STATUS_FILE" 2>/dev/null)
      [ -z "$PLAYER" ] && continue

      echo "[editor] Reaching out to $PLAYER (reason: ${OUTREACH_REASON:-none})..."

      PLAYER_NATION=$(jq -r --arg p "$PLAYER" '.players[] | select(.name==$p) | .nation // ""' "$STATUS_FILE" 2>/dev/null || true)
      PLAYER_GOV=$(jq -r --arg p "$PLAYER" '.players[] | select(.name==$p) | .government // ""' "$STATUS_FILE" 2>/dev/null || true)

      SYSTEM_PROMPT=$(build_system_prompt "$PLAYER" "$PLAYER_NATION" "$PLAYER_GOV" "outreach")

      # For outreach, include any prior conversation history
      MESSAGES_JSON=$(build_messages "$PLAYER" 20)
      # Anthropic requires conversation to end with a user message.
      # Add the reason for outreach so the editor knows what angle to take.
      outreach_prompt="(The editor is reaching out to this leader. Reason: ${OUTREACH_REASON:-current events warrant comment}. Write the outreach message based on this angle.)"
      last_role=$(echo "$MESSAGES_JSON" | jq -r '.[-1].role // "none"')
      if [ "$MESSAGES_JSON" = "[]" ] || [ "$last_role" = "assistant" ]; then
        MESSAGES_JSON=$(echo "$MESSAGES_JSON" | jq --arg p "$outreach_prompt" '. + [{"role":"user","content":$p}]')
      fi

      RESPONSE_TEXT=$(call_ai "$SYSTEM_PROMPT" "$MESSAGES_JSON" 2400)

      if [ -z "$RESPONSE_TEXT" ]; then
        echo "[editor] Outreach API call failed for $PLAYER"
        continue
      fi

      # Store as editor message (editor initiates)
      safe_response=$(printf '%s' "$RESPONSE_TEXT" | sed "s/'/''/g")
      sqlite3 "$DB_PATH" "INSERT INTO editor_messages (player_name, role, content, created_at, turn)
        VALUES ('$PLAYER', 'editor', '$safe_response', $NOW, $TURN);" 2>/dev/null

      # Email the player about the outreach
      send_editor_email "$PLAYER" "$RESPONSE_TEXT" "outreach"

      echo "[editor] Outreach to $PLAYER: $(echo "$RESPONSE_TEXT" | head -c 80)..."
      sleep 1
    done
  fi
fi

echo "[editor] Done"
