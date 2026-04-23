#!/opt/homebrew/bin/bash
# =============================================================================
# Comprehensive tests for generate_status_json.sh
#
# Uses real prod save files from test_data/ (lt-game-1.sav.gz through
# lt-game-4.sav.gz) and jq for all JSON assertions.
#
# Requires: bash 5 (for declare -A), jq, sqlite3, gzip
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Test framework
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
ERRORS=""

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS="${ERRORS}\n  FAIL: $1"; echo "  FAIL: $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail "$desc (expected='$expected', got='$actual')"
  fi
}

assert_ne() {
  local desc="$1" not_expected="$2" actual="$3"
  if [ "$not_expected" != "$actual" ]; then
    pass "$desc"
  else
    fail "$desc (should not equal '$not_expected')"
  fi
}

assert_gt() {
  local desc="$1" value="$2" threshold="$3"
  if [ "$value" -gt "$threshold" ] 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc (expected $value > $threshold)"
  fi
}

assert_ge() {
  local desc="$1" value="$2" threshold="$3"
  if [ "$value" -ge "$threshold" ] 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc (expected $value >= $threshold)"
  fi
}

assert_true() {
  local desc="$1" value="$2"
  if [ "$value" = "true" ]; then
    pass "$desc"
  else
    fail "$desc (expected 'true', got '$value')"
  fi
}

assert_false() {
  local desc="$1" value="$2"
  if [ "$value" = "false" ]; then
    pass "$desc"
  else
    fail "$desc (expected 'false', got '$value')"
  fi
}

# jq helpers
jqf() { jq -r "$1" "$WEBROOT/status.json"; }
hjqf() { jq -r "$1" "$SAVE_DIR/history.json"; }

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DATA="$SCRIPT_DIR/test_data"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/generate_status_json.sh"

for req in jq sqlite3 gzip; do
  if ! command -v "$req" &>/dev/null; then
    echo "FATAL: $req not found in PATH"
    exit 1
  fi
done

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
  echo "FATAL: $SCRIPT_UNDER_TEST not found"
  exit 1
fi

for f in lt-game-1.sav.gz lt-game-2.sav.gz lt-game-3.sav.gz lt-game-4.sav.gz \
         turn_start_epoch fcdb_auth.sql server.log; do
  if [ ! -f "$TEST_DATA/$f" ]; then
    echo "FATAL: $TEST_DATA/$f not found"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Setup: create temp environment with real prod data
# ---------------------------------------------------------------------------
echo "=== Setup ==="
TEST_DIR=$(mktemp -d /tmp/freeciv-test-XXXXXX)
trap "rm -rf $TEST_DIR" EXIT

SAVE_DIR="$TEST_DIR/saves"
WEBROOT="$TEST_DIR/www"
DB_PATH="$TEST_DIR/freeciv.sqlite"
LOGFILE="$TEST_DIR/server.log"

mkdir -p "$SAVE_DIR" "$WEBROOT"

# Copy save files
cp "$TEST_DATA"/lt-game-*.sav.gz "$SAVE_DIR/"

# Copy support files
cp "$TEST_DATA/turn_start_epoch" "$SAVE_DIR/turn_start_epoch"
cp "$TEST_DATA/server.log" "$LOGFILE"

# Create sqlite DB from SQL dump
sqlite3 "$DB_PATH" < "$TEST_DATA/fcdb_auth.sql"

# Read expected turn_start_epoch
EXPECTED_TSE=$(cat "$TEST_DATA/turn_start_epoch" | tr -d '[:space:]')

echo "  Test dir: $TEST_DIR"
echo "  Turn start epoch: $EXPECTED_TSE"

# =============================================================================
# Run 1: Generate status JSON with --rebuild-history (seeds history from all saves)
# =============================================================================
echo ""
echo "=== Run 1: Generating status JSON (with --rebuild-history) ==="
SAVE_DIR="$SAVE_DIR" \
  WEBROOT="$WEBROOT" \
  DB_PATH="$DB_PATH" \
  LOGFILE="$LOGFILE" \
  SERVER_HOST="freeciv.andrewmcgrath.info" \
  /opt/homebrew/bin/bash "$SCRIPT_UNDER_TEST" --no-live --rebuild-history 2>&1

if [ ! -f "$WEBROOT/status.json" ]; then
  echo "FATAL: status.json was not generated"
  exit 1
fi

# Validate it's valid JSON
if ! jq . "$WEBROOT/status.json" >/dev/null 2>&1; then
  echo "FATAL: status.json is not valid JSON"
  exit 1
fi
echo "  status.json generated and valid"

if [ ! -f "$SAVE_DIR/history.json" ]; then
  echo "FATAL: history.json was not generated"
  exit 1
fi

if ! jq . "$SAVE_DIR/history.json" >/dev/null 2>&1; then
  echo "FATAL: history.json is not valid JSON"
  exit 1
fi
echo "  history.json generated and valid"

# =============================================================================
# Test: meta
# =============================================================================
echo ""
echo "--- meta ---"
assert_eq "meta.server_host" \
  "freeciv.andrewmcgrath.info" "$(jqf '.meta.server_host')"
assert_eq "meta.server_port" \
  "5556" "$(jqf '.meta.server_port')"
assert_eq "meta.game_version" \
  "3.2.3" "$(jqf '.meta.game_version')"
assert_eq "meta.ruleset" \
  "civ2civ3" "$(jqf '.meta.ruleset')"
assert_ne "meta.join_form_url is not null" \
  "null" "$(jqf '.meta.join_form_url')"
assert_ne "meta.join_form_url is not empty" \
  "" "$(jqf '.meta.join_form_url')"

# generated_epoch should be a valid unix timestamp (> 2020-01-01)
GEN_EPOCH=$(jqf '.meta.generated_epoch')
assert_gt "meta.generated_epoch is valid unix timestamp" "$GEN_EPOCH" "1577836800"

assert_ne "meta.generated_at is not null" \
  "null" "$(jqf '.meta.generated_at')"

# =============================================================================
# Test: game state
# =============================================================================
echo ""
echo "--- game state ---"
assert_eq "game.turn == 4" \
  "4" "$(jqf '.game.turn')"
assert_eq "game.year == -3850" \
  "-3850" "$(jqf '.game.year')"
assert_eq "game.year_display == '3850 BC'" \
  "3850 BC" "$(jqf '.game.year_display')"
assert_eq "game.server_status == 'Online'" \
  "Online" "$(jqf '.game.server_status')"
assert_eq "game.registered_player_count == 15" \
  "15" "$(jqf '.game.registered_player_count')"
assert_eq "game.turn_timeout == 82800" \
  "82800" "$(jqf '.game.turn_timeout')"
assert_eq "game.turn_start_epoch matches test data" \
  "$EXPECTED_TSE" "$(jqf '.game.turn_start_epoch')"

EXPECTED_DEADLINE=$((EXPECTED_TSE + 82800))
assert_eq "game.deadline_epoch == turn_start_epoch + 82800" \
  "$EXPECTED_DEADLINE" "$(jqf '.game.deadline_epoch')"

# gazette_publishing defaults to null when no marker file exists
assert_eq "game.gazette_publishing == null when no marker" \
  "null" "$(jqf '.game.gazette_publishing')"

SAVE_MTIME=$(jqf '.game.save_mtime')
assert_gt "game.save_mtime > 0" "$SAVE_MTIME" "0"

# status.json should NOT contain history or player_names
assert_eq "status.json has no history key" \
  "null" "$(jqf '.history')"
assert_eq "status.json has no player_names key" \
  "null" "$(jqf '.player_names')"

# =============================================================================
# Test: players
# =============================================================================
echo ""
echo "--- players ---"
PLAYER_COUNT=$(jqf '.players | length')
assert_eq "15 players total" "15" "$PLAYER_COUNT"

# No barbarian
LION_COUNT=$(jqf '[.players[] | select(.name == "Lion")] | length')
assert_eq "No Lion (barbarian) player" "0" "$LION_COUNT"

# All required fields present on every player
FIELD_CHECK=$(jq -r '.players[] | keys | length >= 13 | tostring' "$WEBROOT/status.json" | sort -u)
assert_eq "All players have at least 13 fields" "true" "$FIELD_CHECK"

# Players sorted by score descending
IS_SORTED=$(jqf '
  [.players | to_entries[] | {idx: .key, score: .value.score}]
  | [range(1; length) as $i | .[$i-1].score >= .[$i].score] | all | tostring')
assert_true "Players sorted by score descending" "$IS_SORTED"

# Ranks are 1 through 15
RANKS=$(jqf '[.players[].rank] | sort')
EXPECTED_RANKS=$(jq -n '[range(1;16)]')
assert_eq "Ranks are 1 through 15" "$EXPECTED_RANKS" "$RANKS"

# phase_done: exactly 6 true
DONE_TRUE_COUNT=$(jqf '[.players[] | select(.phase_done == true)] | length')
assert_eq "Exactly 6 players with phase_done=true" "6" "$DONE_TRUE_COUNT"

# phase_done: exactly 9 false
DONE_FALSE_COUNT=$(jqf '[.players[] | select(.phase_done == false)] | length')
assert_eq "Exactly 9 players with phase_done=false" "9" "$DONE_FALSE_COUNT"

# Specific players done
DONE_NAMES=$(jq -c '[.players[] | select(.phase_done == true) | .name] | sort' "$WEBROOT/status.json")
EXPECTED_DONE='["Andrew","Jess","Kimjongboom","Minikeg","Peter","Tracymakes"]'
assert_eq "Done players: Andrew, Jess, Kimjongboom, Minikeg, Peter, Tracymakes" \
  "$EXPECTED_DONE" "$DONE_NAMES"

# Specific players not done
NOT_DONE_NAMES=$(jq -c '[.players[] | select(.phase_done == false) | .name] | sort' "$WEBROOT/status.json")
EXPECTED_NOT_DONE='["Blakkout","DetectiveG","Hyfen","Ihop","Jamsem24","Kroony","Shazow","Shogun","Tankerjon"]'
assert_eq "Not-done players: 9 expected names" \
  "$EXPECTED_NOT_DONE" "$NOT_DONE_NAMES"

# All is_alive are true (nobody dead in turn 4)
ALL_ALIVE=$(jqf '[.players[].is_alive] | all | tostring')
assert_true "All players alive in turn 4" "$ALL_ALIVE"

# Nation names are capitalized (first letter uppercase)
BAD_NATIONS=$(jqf '[.players[].nation | select(test("^[a-z]"))] | length')
assert_eq "All nation names start with uppercase" "0" "$BAD_NATIONS"

# Score, cities, units, gold are integers >= 0
BAD_STATS=$(jqf '[.players[] | select(.score < 0 or .cities < 0 or .units < 0 or .gold < 0)] | length')
assert_eq "All stat fields >= 0" "0" "$BAD_STATS"

# Score, cities, units, gold are integers (not floats)
INT_CHECK=$(jqf '[.players[] | .score, .cities, .units, .gold | . == (. | floor)] | all | tostring')
assert_true "All stat fields are integers" "$INT_CHECK"

# missed_turns and total_turns exist on all players
HAS_MISSED=$(jqf '[.players[] | has("missed_turns")] | all | tostring')
assert_true "All players have missed_turns" "$HAS_MISSED"
HAS_TOTAL=$(jqf '[.players[] | has("total_turns")] | all | tostring')
assert_true "All players have total_turns" "$HAS_TOTAL"

# total_turns == 3 for all (3 completed turns: 1, 2, 3)
ALL_TOTAL_3=$(jqf '[.players[] | select(.total_turns == 3)] | length')
assert_eq "All 15 players have total_turns == 3" "15" "$ALL_TOTAL_3"

# Andrew missed 0 turns, Blakkout missed 2
ANDREW_MISSED=$(jqf '[.players[] | select(.name == "Andrew") | .missed_turns] | .[0]')
assert_eq "Andrew missed_turns == 0" "0" "$ANDREW_MISSED"
BLAKKOUT_MISSED=$(jqf '[.players[] | select(.name == "Blakkout") | .missed_turns] | .[0]')
assert_eq "Blakkout missed_turns == 2" "2" "$BLAKKOUT_MISSED"

# missed_turns <= total_turns for everyone
BAD_MISSED=$(jqf '[.players[] | select(.missed_turns > .total_turns)] | length')
assert_eq "missed_turns <= total_turns for all" "0" "$BAD_MISSED"

# =============================================================================
# Test: attendance.json
# =============================================================================
echo ""
echo "--- attendance.json ---"
ATTEND_FILE="$SAVE_DIR/attendance.json"
if [ -f "$ATTEND_FILE" ] && jq . "$ATTEND_FILE" >/dev/null 2>&1; then
  pass "attendance.json exists and is valid JSON"
else
  fail "attendance.json missing or invalid"
fi

ATT_PLAYERS=$(jq 'keys | length' "$ATTEND_FILE")
assert_eq "attendance.json has 15 players" "15" "$ATT_PLAYERS"

# No barbarians in attendance
ATT_LION=$(jq -r 'has("Lion") | tostring' "$ATTEND_FILE")
assert_false "No Lion in attendance" "$ATT_LION"

# Attendance has expected fields
ATT_FIELDS=$(jq -c 'to_entries[0].value | keys | sort' "$ATTEND_FILE")
assert_eq "Attendance entry has expected fields" '["missed","missed_turns","total_turns"]' "$ATT_FIELDS"

# Symlink exists
if [ -L "$WEBROOT/attendance.json" ]; then
  pass "attendance.json symlinked in webroot"
else
  fail "attendance.json not symlinked in webroot"
fi

# =============================================================================
# Test: activity
# =============================================================================
echo ""
echo "--- activity ---"
assert_eq "activity.done_count == 6" \
  "6" "$(jqf '.activity.done_count')"
assert_eq "activity.total_players == 15" \
  "15" "$(jqf '.activity.total_players')"

ONLINE_COUNT=$(jqf '.activity.online_count')
assert_ge "activity.online_count >= 0" "$ONLINE_COUNT" "0"

LOGGED_IN=$(jqf '.activity.logged_in_count')
DONE_CT=$(jqf '.activity.done_count')
assert_ge "activity.logged_in_count >= done_count" "$LOGGED_IN" "$DONE_CT"

# =============================================================================
# Test: history.json
# =============================================================================
echo ""
echo "--- history.json ---"
HIST_LEN=$(hjqf '. | length')
assert_eq "4 history entries" "4" "$HIST_LEN"

HIST_TURNS=$(jq -c '[.[].turn]' "$SAVE_DIR/history.json")
assert_eq "History turns are [1,2,3,4]" "[1,2,3,4]" "$HIST_TURNS"

# Each entry has a players object
HIST_HAS_PLAYERS=$(hjqf '[.[] | has("players")] | all | tostring')
assert_true "Each history entry has players object" "$HIST_HAS_PLAYERS"

# No Lion in any history entry
LION_IN_HIST=$(hjqf '[.[].players | has("Lion")] | any | tostring')
assert_false "No Lion in any history entry" "$LION_IN_HIST"

# First entry is turn 1
assert_eq "history[0].turn == 1" "1" "$(hjqf '.[0].turn')"

# Last entry is turn 4
assert_eq "history[3].turn == 4" "4" "$(hjqf '.[3].turn')"

# Each history entry has year
HIST_HAS_YEAR=$(hjqf '[.[] | has("year")] | all | tostring')
assert_true "Each history entry has year" "$HIST_HAS_YEAR"

# History players have expected fields
HIST_PLAYER_FIELDS=$(jq -c '
  [.[0].players | to_entries[0].value | keys[]] | sort' "$SAVE_DIR/history.json")
EXPECTED_HIST_FIELDS='["cities","gold","government","is_alive","nation","score","techs","unit_types","units"]'
assert_eq "History player objects have expected fields" \
  "$EXPECTED_HIST_FIELDS" "$HIST_PLAYER_FIELDS"

# Symlink exists in webroot
if [ -L "$WEBROOT/history.json" ]; then
  pass "history.json symlinked in webroot"
else
  fail "history.json not symlinked in webroot"
fi

# Player names derivable from history
HIST_NAMES=$(jq -c '[.[].players | keys[]] | unique | sort' "$SAVE_DIR/history.json")
HIST_NAMES_COUNT=$(echo "$HIST_NAMES" | jq 'length')
assert_eq "15 player names in history" "15" "$HIST_NAMES_COUNT"

# No Lion in player names from history
LION_IN_NAMES=$(echo "$HIST_NAMES" | jq '[.[] | select(. == "Lion")] | length')
assert_eq "No Lion in history player names" "0" "$LION_IN_NAMES"

# =============================================================================
# Test: idempotency (run 2 — should not duplicate history entries)
# =============================================================================
echo ""
echo "=== Run 2: Idempotency check ==="
# Save run 1 output
cp "$WEBROOT/status.json" "$TEST_DIR/run1.json"

# Run again (normal mode, no --rebuild-history)
SAVE_DIR="$SAVE_DIR" \
  WEBROOT="$WEBROOT" \
  DB_PATH="$DB_PATH" \
  LOGFILE="$LOGFILE" \
  SERVER_HOST="freeciv.andrewmcgrath.info" \
  /opt/homebrew/bin/bash "$SCRIPT_UNDER_TEST" --no-live 2>&1

cp "$WEBROOT/status.json" "$TEST_DIR/run2.json"

echo ""
echo "--- idempotency ---"

# Compare everything except generated_at and generated_epoch
RUN1_STRIPPED=$(jq 'del(.meta.generated_at, .meta.generated_epoch)' "$TEST_DIR/run1.json")
RUN2_STRIPPED=$(jq 'del(.meta.generated_at, .meta.generated_epoch)' "$TEST_DIR/run2.json")

if [ "$RUN1_STRIPPED" = "$RUN2_STRIPPED" ]; then
  pass "Run 1 and Run 2 produce identical JSON (excluding timestamps)"
else
  fail "Run 1 and Run 2 differ (excluding timestamps)"
  diff <(echo "$RUN1_STRIPPED" | jq -S .) <(echo "$RUN2_STRIPPED" | jq -S .) | head -30
fi

# Spot-check key fields are still correct after second run
assert_eq "Run 2: turn still 4" "4" "$(jqf '.game.turn')"
assert_eq "Run 2: still 15 players" "15" "$(jqf '.players | length')"
assert_eq "Run 2: still 6 done" "6" "$(jqf '.activity.done_count')"

# History should NOT have duplicates
HIST_LEN_RUN2=$(hjqf '. | length')
assert_eq "Run 2: history still has 4 entries (not 8)" "4" "$HIST_LEN_RUN2"

# =============================================================================
# Test: stale state
# =============================================================================
echo ""
echo "=== Run 3: Stale state test ==="
# Create a modified copy of lt-game-4.sav.gz with ALL phase_done=FALSE
STALE_TMP=$(mktemp /tmp/freeciv-stale-XXXXXX)
gzip -dc "$SAVE_DIR/lt-game-4.sav.gz" \
  | sed 's/^phase_done=TRUE/phase_done=FALSE/g' \
  | gzip -c > "$STALE_TMP.gz"
cp "$STALE_TMP.gz" "$SAVE_DIR/lt-game-4.sav.gz"
rm -f "$STALE_TMP" "$STALE_TMP.gz"

SAVE_DIR="$SAVE_DIR" \
  WEBROOT="$WEBROOT" \
  DB_PATH="$DB_PATH" \
  LOGFILE="$LOGFILE" \
  SERVER_HOST="freeciv.andrewmcgrath.info" \
  /opt/homebrew/bin/bash "$SCRIPT_UNDER_TEST" --no-live 2>&1

echo ""
echo "--- stale state checks ---"
assert_eq "Stale: done_count == 0" \
  "0" "$(jqf '.activity.done_count')"

STALE_DONE=$(jqf '[.players[] | select(.phase_done == true)] | length')
assert_eq "Stale: no player has phase_done=true" "0" "$STALE_DONE"

# All players should now be phase_done=false
STALE_NOT_DONE=$(jqf '[.players[] | select(.phase_done == false)] | length')
assert_eq "Stale: all 15 players phase_done=false" "15" "$STALE_NOT_DONE"

# Other fields should still be correct (no leakage from prior run)
assert_eq "Stale: turn still 4" "4" "$(jqf '.game.turn')"
assert_eq "Stale: still 15 players" "15" "$(jqf '.players | length')"

# History should still have exactly 4 entries (turn 4 already existed)
assert_eq "Stale: history still 4 entries" "4" "$(hjqf '. | length')"

# =============================================================================
# Test: corrupted history.json recovery
# =============================================================================
echo ""
echo "=== Run 4: Corrupted history.json recovery ==="
echo "NOT VALID JSON" > "$SAVE_DIR/history.json"

SAVE_DIR="$SAVE_DIR" \
  WEBROOT="$WEBROOT" \
  DB_PATH="$DB_PATH" \
  LOGFILE="$LOGFILE" \
  SERVER_HOST="freeciv.andrewmcgrath.info" \
  /opt/homebrew/bin/bash "$SCRIPT_UNDER_TEST" --no-live 2>&1

echo ""
echo "--- corruption recovery ---"
if jq . "$SAVE_DIR/history.json" >/dev/null 2>&1; then
  pass "Recovered from corrupted history.json"
else
  fail "Failed to recover from corrupted history.json"
fi

# Should have 1 entry (just the current turn, since we lost history)
RECOVERY_LEN=$(hjqf '. | length')
assert_eq "Recovery: history has 1 entry (current turn only)" "1" "$RECOVERY_LEN"
assert_eq "Recovery: entry is turn 4" "4" "$(hjqf '.[0].turn')"

# =============================================================================
# Test: gazette_publishing marker is surfaced in status.json
# =============================================================================
echo ""
echo "=== Run 6: gazette_publishing marker ==="
# Write the marker containing a target turn (the turn whose edition is being
# generated). start.sh sets this at the beginning of turn-change processing.
echo "5" > "$SAVE_DIR/gazette-publishing"

SAVE_DIR="$SAVE_DIR" \
  WEBROOT="$WEBROOT" \
  DB_PATH="$DB_PATH" \
  LOGFILE="$LOGFILE" \
  SERVER_HOST="freeciv.andrewmcgrath.info" \
  /opt/homebrew/bin/bash "$SCRIPT_UNDER_TEST" --no-live 2>&1

echo ""
echo "--- gazette_publishing marker ---"
assert_eq "game.gazette_publishing == 5 when marker set to 5" \
  "5" "$(jqf '.game.gazette_publishing')"

# Remove the marker and verify it's cleared on next run
rm -f "$SAVE_DIR/gazette-publishing"
SAVE_DIR="$SAVE_DIR" \
  WEBROOT="$WEBROOT" \
  DB_PATH="$DB_PATH" \
  LOGFILE="$LOGFILE" \
  SERVER_HOST="freeciv.andrewmcgrath.info" \
  /opt/homebrew/bin/bash "$SCRIPT_UNDER_TEST" --no-live 2>&1

assert_eq "game.gazette_publishing == null after marker removed" \
  "null" "$(jqf '.game.gazette_publishing')"

# A garbage marker (non-integer) should be treated as "not publishing"
echo "not-a-number" > "$SAVE_DIR/gazette-publishing"
SAVE_DIR="$SAVE_DIR" \
  WEBROOT="$WEBROOT" \
  DB_PATH="$DB_PATH" \
  LOGFILE="$LOGFILE" \
  SERVER_HOST="freeciv.andrewmcgrath.info" \
  /opt/homebrew/bin/bash "$SCRIPT_UNDER_TEST" --no-live 2>&1

assert_eq "game.gazette_publishing == null when marker is garbage" \
  "null" "$(jqf '.game.gazette_publishing')"
rm -f "$SAVE_DIR/gazette-publishing"

# =============================================================================
# Test: regression guards — typos and bad fallbacks we've previously removed
# =============================================================================
echo ""
echo "--- regression guards ---"

# The gazette previously filtered diplomacy by `.state`, but the actual field
# is `.status`. That typo produced empty active_wars/active_alliances and led
# the AI to hallucinate "world peace" headlines. Catch a re-introduction.
GAZETTE_SH="$SCRIPT_DIR/generate_gazette.sh"
BAD_STATE_USES=$({ grep -cE '\$all_dipl\[\] \| select\(\.state ==' "$GAZETTE_SH" || true; } | head -1)
assert_eq "generate_gazette.sh uses .status not .state on \$all_dipl" \
  "0" "$BAD_STATE_USES"
GOOD_STATUS_USES=$({ grep -cE '\$all_dipl\[\] \| select\(\.status ==' "$GAZETTE_SH" || true; } | head -1)
assert_ge "generate_gazette.sh has at least 2 .status filters on \$all_dipl" \
  "$GOOD_STATUS_USES" "2"

# start.sh used to seed a wildly wrong year from a linear estimate when
# status.json was unreadable: year = -4000 + (turn - 1) * 50. Turn 81 landed
# exactly at year=0, producing "Year 0 AD" emails. Make sure that never comes
# back.
START_SH="$SCRIPT_DIR/start.sh"
BAD_YEAR_EST=$({ grep -cE 'year=\$\(\(\(-4000.*turn.*-.*1.*\*.*50\)\)\)' "$START_SH" || true; } | head -1)
assert_eq "start.sh no longer uses linear year estimate" \
  "0" "$BAD_YEAR_EST"

# =============================================================================
# Test: rebuild-history recovers all turns
# =============================================================================
echo ""
echo "=== Run 5: --rebuild-history restores all turns ==="
SAVE_DIR="$SAVE_DIR" \
  WEBROOT="$WEBROOT" \
  DB_PATH="$DB_PATH" \
  LOGFILE="$LOGFILE" \
  SERVER_HOST="freeciv.andrewmcgrath.info" \
  /opt/homebrew/bin/bash "$SCRIPT_UNDER_TEST" --no-live --rebuild-history 2>&1

echo ""
echo "--- rebuild check ---"
assert_eq "Rebuild: history has 4 entries" "4" "$(hjqf '. | length')"
assert_eq "Rebuild: turns are [1,2,3,4]" "[1,2,3,4]" "$(jq -c '[.[].turn]' "$SAVE_DIR/history.json")"

# =============================================================================
# Test: declare -A regression
# =============================================================================
echo ""
echo "--- declare -A regression test ---"

# Prove unset+declare works (the fix)
RESULT=$(/opt/homebrew/bin/bash -c '
  declare -A M
  M[a]=1
  M[b]=2
  unset M
  declare -A M
  M[c]=3
  echo "a=${M[a]:-EMPTY} b=${M[b]:-EMPTY} c=${M[c]:-EMPTY}"
')
assert_eq "unset+declare clears associative array" \
  "a=EMPTY b=EMPTY c=3" "$RESULT"

# Prove the OLD broken pattern retains stale values
RESULT_OLD=$(/opt/homebrew/bin/bash -c '
  declare -A M
  M[a]=1
  M[b]=2
  declare -A M
  M[c]=3
  echo "a=${M[a]:-EMPTY} b=${M[b]:-EMPTY} c=${M[c]:-EMPTY}"
')
assert_eq "declare-only (old bug) retains stale values" \
  "a=1 b=2 c=3" "$RESULT_OLD"

# Verify the script under test uses the correct unset+declare pattern
UNSET_COUNT=$(grep -c 'unset.*_MAP' "$SCRIPT_UNDER_TEST" || echo 0)
DECLARE_A_COUNT=$(grep -c 'declare -A.*_MAP' "$SCRIPT_UNDER_TEST" || echo 0)
assert_ge "Script has unset before each declare -A" "$UNSET_COUNT" "$DECLARE_A_COUNT"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "==========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "==========================================="
if [ "$FAIL" -gt 0 ]; then
  echo -e "\nFailures:$ERRORS"
  exit 1
else
  echo "  All tests passed."
  exit 0
fi
