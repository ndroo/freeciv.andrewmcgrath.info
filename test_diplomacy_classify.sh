#!/opt/homebrew/bin/bash
# =============================================================================
# Tests for the diplomacy-event classifier (lib_diplomacy.sh).
#
# Freeciv has automatic state transitions that look like signed treaties but
# aren't — the classifier exists so the Chronicle AI can tell them apart.
# These tests pin the category / negotiated_this_turn mapping for every
# transition we care about.
# =============================================================================
set -euo pipefail

PASS=0
FAIL=0
ERRORS=""

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS="${ERRORS}\n  FAIL: $1"; echo "  FAIL: $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$desc";
  else fail "$desc (expected '$expected', got '$actual')"; fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib_diplomacy.sh
. "$SCRIPT_DIR/lib_diplomacy.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not in PATH"; exit 1; }
[ -n "${CLASSIFY_EVENT_JQ_DEF:-}" ] || { echo "FATAL: CLASSIFY_EVENT_JQ_DEF not defined"; exit 1; }

# Helper: run the classifier against a single event JSON and print a field.
classify() {
  local event_json="$1" field="$2"
  echo "$event_json" | jq -r "$CLASSIFY_EVENT_JQ_DEF classify_event | .$field"
}

make_event() {
  local from="$1" to="$2"
  jq -n --arg from "$from" --arg to "$to" \
    '{players: ["Alice","Bob"], from: $from, to: $to, turn: 10, year: -1000}'
}

# ---------------------------------------------------------------------------
# Per-transition tests
# ---------------------------------------------------------------------------

echo ""
echo "=== Per-transition classification ==="

# Never met → anything: first_contact, not negotiated
E=$(make_event "Never met" "Armistice")
assert_eq "Never met→Armistice: category" "first_contact" "$(classify "$E" category)"
assert_eq "Never met→Armistice: not negotiated" "false" "$(classify "$E" negotiated_this_turn)"

E=$(make_event "Never met" "Contact")
assert_eq "Never met→Contact: category" "first_contact" "$(classify "$E" category)"
assert_eq "Never met→Contact: not negotiated" "false" "$(classify "$E" negotiated_this_turn)"

# War declarations: negotiated (player action)
E=$(make_event "Peace" "War")
assert_eq "Peace→War: category" "war_declared" "$(classify "$E" category)"
assert_eq "Peace→War: negotiated" "true" "$(classify "$E" negotiated_this_turn)"

E=$(make_event "Armistice" "War")
assert_eq "Armistice→War: category" "war_declared" "$(classify "$E" category)"
assert_eq "Armistice→War: negotiated" "true" "$(classify "$E" negotiated_this_turn)"

# Cease-fire signings: negotiated (requires treaty)
E=$(make_event "War" "Ceasefire")
assert_eq "War→Ceasefire: category" "ceasefire_signed" "$(classify "$E" category)"
assert_eq "War→Ceasefire: negotiated" "true" "$(classify "$E" negotiated_this_turn)"

# Ceasefire maturing: automatic
E=$(make_event "Ceasefire" "Armistice")
assert_eq "Ceasefire→Armistice: category" "armistice_began" "$(classify "$E" category)"
assert_eq "Ceasefire→Armistice: NOT negotiated" "false" "$(classify "$E" negotiated_this_turn)"

# Armistice maturing into peace: AUTOMATIC (this is the turn 45 bug!)
E=$(make_event "Armistice" "Peace")
assert_eq "Armistice→Peace: category" "peace_took_effect" "$(classify "$E" category)"
assert_eq "Armistice→Peace: NOT negotiated (turn 45 regression)" \
  "false" "$(classify "$E" negotiated_this_turn)"

# Peace → Alliance: negotiated
E=$(make_event "Peace" "Alliance")
assert_eq "Peace→Alliance: category" "alliance_formed" "$(classify "$E" category)"
assert_eq "Peace→Alliance: negotiated" "true" "$(classify "$E" negotiated_this_turn)"

# Contact → Armistice: automatic (freeciv default)
E=$(make_event "Contact" "Armistice")
assert_eq "Contact→Armistice: category" "armistice_began" "$(classify "$E" category)"
assert_eq "Contact→Armistice: NOT negotiated" "false" "$(classify "$E" negotiated_this_turn)"

# Alliance → Peace: "other" category (dropping alliance, not a clean
# real-world analogue — leave it loose rather than misclassify)
E=$(make_event "Alliance" "Peace")
# Under current rules, .to == "Peace" (non-Armistice origin) → peace_signed
assert_eq "Alliance→Peace: category" "peace_signed" "$(classify "$E" category)"
assert_eq "Alliance→Peace: negotiated" "true" "$(classify "$E" negotiated_this_turn)"

# ---------------------------------------------------------------------------
# Preserved fields: event retains players / from / to / turn / year
# ---------------------------------------------------------------------------
echo ""
echo "=== Preserved input fields ==="
E=$(make_event "Armistice" "Peace")
assert_eq "players preserved" '["Alice","Bob"]' "$(echo "$E" | jq -c "$CLASSIFY_EVENT_JQ_DEF classify_event | .players")"
assert_eq "from preserved" "Armistice" "$(classify "$E" from)"
assert_eq "to preserved" "Peace" "$(classify "$E" to)"
assert_eq "turn preserved" "10" "$(classify "$E" turn)"
assert_eq "year preserved" "-1000" "$(classify "$E" year)"

# ---------------------------------------------------------------------------
# The turn-45 regression fixture
# ---------------------------------------------------------------------------
# These are the exact events recorded in production for turn 45 — every single
# one of them is an automatic transition or first contact. The AI's claim of
# "Andrew signed five treaties in one turning" was impossible from this data.
echo ""
echo "=== Turn 45 regression fixture ==="
FIXTURE=$(cat <<'EOF'
[
  {"turn": 45, "year": -1800, "players": ["Andrew","Hyfen"],  "from": "Armistice", "to": "Peace"},
  {"turn": 45, "year": -1800, "players": ["Andrew","Shazow"], "from": "Armistice", "to": "Peace"},
  {"turn": 45, "year": -1800, "players": ["Andrew","Shogun"], "from": "Contact",   "to": "Armistice"},
  {"turn": 45, "year": -1800, "players": ["Andrew","UncleS"], "from": "Never met", "to": "Armistice"},
  {"turn": 45, "year": -1800, "players": ["Peter","UncleS"],  "from": "Armistice", "to": "Peace"}
]
EOF
)

CLASSIFIED=$(echo "$FIXTURE" | jq "$CLASSIFY_EVENT_JQ_DEF"' [.[] | classify_event]')

NEG_COUNT=$(echo "$CLASSIFIED" | jq '[.[] | select(.negotiated_this_turn == true)] | length')
assert_eq "Turn 45 fixture: zero events were negotiated this turn" "0" "$NEG_COUNT"

AUTO_COUNT=$(echo "$CLASSIFIED" | jq '[.[] | select(.negotiated_this_turn == false)] | length')
assert_eq "Turn 45 fixture: all 5 events were automatic / first-contact" "5" "$AUTO_COUNT"

# Andrew's true treaty count for turn 45 should be ZERO, not five
ANDREW_TREATIES=$(echo "$CLASSIFIED" | jq '[.[] | select(.negotiated_this_turn == true and (.players | contains(["Andrew"])))] | length')
assert_eq "Turn 45 fixture: Andrew signed ZERO treaties this turn" "0" "$ANDREW_TREATIES"

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
