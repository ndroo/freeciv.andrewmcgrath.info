#!/opt/homebrew/bin/bash
# =============================================================================
# Tests for turn_notify.sh validation logic.
#
# turn_notify.sh exits with "No players with email addresses found" when the
# fcdb_auth table is empty — we use that to let all the validation code run
# without actually attempting SMTP.
#
# What we're guarding against:
#   1. Year=0 sentinel leaking into emails as "Year 0 AD" (happened because
#      generate_status_json.sh's defaults survived when a save file couldn't
#      be parsed).
#   2. Turn mismatch in status.json (stale / racing generator).
#   3. Gazette publishing marker present — don't ship in-flight editions.
#   4. Gazette latest entry doesn't match TURN-1 (stale gazette.json).
# =============================================================================
set -euo pipefail

PASS=0
FAIL=0
ERRORS=""

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS="${ERRORS}\n  FAIL: $1"; echo "  FAIL: $1"; }

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    pass "$desc"
  else
    fail "$desc (expected to find: $needle)"
    echo "    actual output:"
    echo "$haystack" | sed 's/^/      /'
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    fail "$desc (did NOT expect to find: $needle)"
    echo "    actual output:"
    echo "$haystack" | sed 's/^/      /'
  else
    pass "$desc"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/turn_notify.sh"

for req in jq sqlite3; do
  command -v "$req" >/dev/null 2>&1 || { echo "FATAL: $req not in PATH"; exit 1; }
done
[ -f "$SCRIPT_UNDER_TEST" ] || { echo "FATAL: $SCRIPT_UNDER_TEST not found"; exit 1; }

# ---------------------------------------------------------------------------
# Setup: temp dir with empty DB (so the script exits without sending SMTP)
# and a stub email_enabled.settings file.
# ---------------------------------------------------------------------------
TEST_DIR=$(mktemp -d /tmp/freeciv-notify-test-XXXXXX)
trap "rm -rf $TEST_DIR" EXIT

SAVE_DIR="$TEST_DIR/saves"
WEBROOT="$TEST_DIR/www"
DB_PATH="$TEST_DIR/freeciv.sqlite"
mkdir -p "$SAVE_DIR" "$WEBROOT" /tmp/test-opt-freeciv-stub 2>/dev/null || true

# Empty fcdb_auth schema — no rows, so EMAILS is empty and the script bails
# after validation but before any SMTP.
sqlite3 "$DB_PATH" "CREATE TABLE fcdb_auth (id INTEGER PRIMARY KEY, name TEXT, email TEXT);"

# Stub email_enabled.settings — turn_notify.sh reads this from a hardcoded
# path, so we use a shim by symlinking the script's expected location into
# a writeable place. The script reads /opt/freeciv/email_enabled.settings
# which we can't control, so we just set EMAIL_ENABLED via env... except the
# script hard-codes the file read. Work around by patching the path via a
# wrapper that sets it in the environment first.
EMAIL_SETTINGS="$TEST_DIR/email_enabled.settings"
echo "true" > "$EMAIL_SETTINGS"

# Build a minimal valid gazette.json (two entries, turns 3 and 4)
cat > "$SAVE_DIR/gazette.json" <<'EOF'
[
  {"turn": 3, "year": -3900, "year_display": "3900 BC", "headline": "OLD NEWS",
   "sections": {"front_page": {"byline": "Reporter", "content": "<p>old</p>"}}},
  {"turn": 4, "year": -3850, "year_display": "3850 BC", "headline": "FRESH NEWS",
   "sections": {"front_page": {"byline": "Reporter", "content": "<p>fresh</p>"}}}
]
EOF
ln -sf "$SAVE_DIR/gazette.json" "$WEBROOT/gazette.json"

# Helper: write a status.json with given turn and year
write_status() {
  local turn="$1" year="$2" year_display="$3"
  cat > "$WEBROOT/status.json" <<EOF
{
  "meta": {"generated_at": "test", "generated_epoch": 1700000000,
           "server_host": "test", "server_port": 5556,
           "join_form_url": "", "game_version": "3.2.3", "ruleset": "civ2civ3"},
  "game": {"turn": $turn, "year": $year, "year_display": "$year_display",
           "server_status": "Online", "registered_player_count": 0,
           "deadline_epoch": 1700082800, "turn_timeout": 82800,
           "save_mtime": 1700000000, "turn_start_epoch": 1700000000,
           "gazette_publishing": null},
  "players": [],
  "activity": {"done_count": 0, "online_count": 0, "logged_in_count": 0, "total_players": 0}
}
EOF
}

# Helper: run turn_notify.sh with dummy env so it reaches validation logic
run_notify() {
  local turn_arg="$1"
  # We need to shadow the hard-coded /opt/freeciv/email_enabled.settings path.
  # Since we can't mock it, override via a wrapper: we'll source the script
  # after setting up a chroot-like overlay. Simplest trick: use `env -` plus
  # pointing at a writable /opt/freeciv... not portable.
  # Workaround: just set SES creds to dummy and run. email_enabled.settings
  # check fails silently (exits), so we'll inline the validation by invoking
  # with a path override via sed-patched script. Easier: create a one-shot
  # copy of the script with the settings path swapped for our test file.
  local patched="$TEST_DIR/turn_notify_patched.sh"
  sed "s|/opt/freeciv/email_enabled.settings|$EMAIL_SETTINGS|g" "$SCRIPT_UNDER_TEST" > "$patched"
  chmod +x "$patched"

  SES_SMTP_USER=dummy \
  SES_SMTP_PASS=dummy \
  FROM_EMAIL=test@example.com \
  SERVER_HOST=test.example.com \
  SAVE_DIR="$SAVE_DIR" \
  WEBROOT="$WEBROOT" \
  bash "$patched" "$turn_arg" "0" 2>&1 || true
}

# ---------------------------------------------------------------------------
# Scenario 1: happy path — status.json turn matches, year != 0, gazette
# latest is TURN-1, no publishing marker. Should emit no validation WARNINGs.
# ---------------------------------------------------------------------------
echo ""
echo "=== Scenario 1: happy path ==="
# Override DB_PATH via env: the script reads DB_PATH="/data/saves/freeciv.sqlite"
# at the top. It doesn't take env, so we patch it too.
# Easier: re-patch to point at our test DB.
SCRIPT_PATCHED="$TEST_DIR/turn_notify_patched.sh"
sed -e "s|/opt/freeciv/email_enabled.settings|$EMAIL_SETTINGS|g" \
    -e "s|DB_PATH=\"/data/saves/freeciv.sqlite\"|DB_PATH=\"$DB_PATH\"|" \
    "$SCRIPT_UNDER_TEST" > "$SCRIPT_PATCHED"

run_notify_patched() {
  local turn_arg="$1"
  SES_SMTP_USER=dummy SES_SMTP_PASS=dummy \
  FROM_EMAIL=test@example.com SERVER_HOST=test.example.com \
  SAVE_DIR="$SAVE_DIR" WEBROOT="$WEBROOT" \
  bash "$SCRIPT_PATCHED" "$turn_arg" "0" 2>&1 || true
}

write_status 5 -3800 "3800 BC"
rm -f "$SAVE_DIR/gazette-publishing"
OUT=$(run_notify_patched 5)
assert_not_contains "Happy: no status turn-mismatch warning" "status.json turn=" "$OUT"
assert_not_contains "Happy: no publishing marker warning" "publishing marker present" "$OUT"
assert_not_contains "Happy: no gazette-turn warning" "latest gazette is turn" "$OUT"
# Should exit via "No players" path after passing validation
assert_contains "Happy: reached No-players exit (all validation passed)" \
  "No players with email addresses" "$OUT"

# ---------------------------------------------------------------------------
# Scenario 2: status.json has year=0 (the "Year 0 AD" bug)
# ---------------------------------------------------------------------------
echo ""
echo "=== Scenario 2: year=0 in status.json ==="
write_status 5 0 "0 AD"
OUT=$(run_notify_patched 5)
assert_contains "year=0: warning emitted" \
  "status.json turn=5 year=0 does not match expected turn=5" "$OUT"

# ---------------------------------------------------------------------------
# Scenario 3: status.json has a different turn number (stale generator)
# ---------------------------------------------------------------------------
echo ""
echo "=== Scenario 3: status.json turn mismatch ==="
write_status 3 -3900 "3900 BC"
OUT=$(run_notify_patched 5)
assert_contains "turn mismatch: warning emitted" \
  "status.json turn=3 year=-3900 does not match expected turn=5" "$OUT"

# ---------------------------------------------------------------------------
# Scenario 4: publishing marker present → skip gazette block
# ---------------------------------------------------------------------------
echo ""
echo "=== Scenario 4: gazette-publishing marker present ==="
write_status 5 -3800 "3800 BC"
echo "5" > "$SAVE_DIR/gazette-publishing"
OUT=$(run_notify_patched 5)
assert_contains "publishing marker: warning emitted" \
  "publishing marker present" "$OUT"
rm -f "$SAVE_DIR/gazette-publishing"

# ---------------------------------------------------------------------------
# Scenario 5: gazette.json latest is not TURN-1
# ---------------------------------------------------------------------------
echo ""
echo "=== Scenario 5: gazette latest != TURN-1 ==="
write_status 10 -3400 "3400 BC"
# gazette.json still has latest turn 4; we expect turn 9
OUT=$(run_notify_patched 10)
assert_contains "gazette mismatch: warning emitted" \
  "latest gazette is turn 4, expected 9" "$OUT"

# ---------------------------------------------------------------------------
# Scenario 6: all three failures at once — make sure script doesn't crash
# and each warning fires independently.
# ---------------------------------------------------------------------------
echo ""
echo "=== Scenario 6: combined failures ==="
write_status 5 0 "0 AD"  # year=0 failure
echo "5" > "$SAVE_DIR/gazette-publishing"  # marker failure
OUT=$(run_notify_patched 5)
assert_contains "Combined: year=0 warning" "year=0 does not match" "$OUT"
assert_contains "Combined: publishing marker warning" "publishing marker present" "$OUT"
rm -f "$SAVE_DIR/gazette-publishing"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
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
