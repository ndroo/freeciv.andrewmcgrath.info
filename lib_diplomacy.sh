#!/bin/bash
# Shared jq classifier for freeciv diplomacy-state transitions.
#
# Freeciv has AUTOMATIC state transitions that can look like "signed treaties"
# but aren't — the Chronicle AI used to conflate them, producing headlines
# like "Andrew signs five treaties in one turn" when in reality the player
# had not signed anything that turn; prior armistices had merely matured.
#
# This file is sourced by generate_gazette.sh and test_diplomacy_classify.sh.
# Both invoke jq with "$CLASSIFY_EVENT_JQ_DEF"'... classify_event ...' so the
# definition lives in exactly one place.
#
# Contract: classify_event takes an event {players, from, to, ...} and returns
# the same object enriched with:
#   category:              semantic label
#   negotiated_this_turn:  true if a player took an action THIS turn; false
#                          if this is an automatic freeciv transition or a
#                          first-contact initialization
#   description:           short human-readable blurb
#
# Freeciv state progression reference (civ2civ3):
#   Never met → Contact  (auto on sighting)
#   Contact → Armistice  (auto, default after contact)
#   War → Ceasefire      (PLAYER action — requires a treaty)
#   Ceasefire → Armistice (auto, after the cease-fire period expires)
#   Armistice → Peace    (auto, after the armistice period expires; the
#                         underlying peace treaty was locked in when the
#                         cease-fire was signed, many turns earlier)
#   Peace → Alliance     (PLAYER action)
#   * → War              (PLAYER action — declaration)

CLASSIFY_EVENT_JQ_DEF='
def classify_event:
  . as $e |
  (if $e.from == "Never met" then
     {category: "first_contact", negotiated_this_turn: false,
      description: ("first contact — default initial state is " + $e.to)}
   elif $e.to == "War" then
     {category: "war_declared", negotiated_this_turn: true,
      description: ("war declared (was " + $e.from + ")")}
   elif $e.from == "War" and $e.to == "Ceasefire" then
     {category: "ceasefire_signed", negotiated_this_turn: true,
      description: "cease-fire signed — the fighting has paused"}
   elif $e.from == "Ceasefire" and $e.to == "Armistice" then
     {category: "armistice_began", negotiated_this_turn: false,
      description: "cease-fire matured into armistice (AUTOMATIC — no new agreement)"}
   elif $e.from == "Armistice" and $e.to == "Peace" then
     {category: "peace_took_effect", negotiated_this_turn: false,
      description: "armistice matured into peace (AUTOMATIC — the peace treaty was signed in an earlier turn)"}
   elif $e.to == "Alliance" then
     {category: "alliance_formed", negotiated_this_turn: true,
      description: ("alliance formed (was " + $e.from + ")")}
   elif $e.from == "Contact" and $e.to == "Armistice" then
     {category: "armistice_began", negotiated_this_turn: false,
      description: "contact settled into armistice (AUTOMATIC — freeciv default after first contact)"}
   elif $e.to == "Peace" then
     {category: "peace_signed", negotiated_this_turn: true,
      description: ("peace signed directly (was " + $e.from + ")")}
   else
     {category: "other", negotiated_this_turn: false,
      description: ($e.from + " → " + $e.to)}
   end
  ) + {players: $e.players, from: $e.from, to: $e.to, turn: ($e.turn // null), year: ($e.year // null)};
'
export CLASSIFY_EVENT_JQ_DEF
