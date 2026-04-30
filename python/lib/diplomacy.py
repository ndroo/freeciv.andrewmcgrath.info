"""Build diplomacy.json: per-pair relationships, history of state changes,
combat-pair set across the whole game.

Output schema (matches the existing bash output exactly so consumers don't
need to change):

    {
      "turn": int,                        # latest turn covered
      "current": [                        # current relationships, latest turn
        {
          "players": [name1, name2],
          "status": str,                  # "Contact" | "War" | "Peace" | ...
          "closest": str,
          "first_contact_turn": int,
          "has_reason_to_cancel": bool,
          "embassy": bool,
          "shared_vision": bool
        },
        ...
      ],
      "events": [                         # state-change history across turns
        {"turn": int, "year": int, "players": [n1, n2], "from": str, "to": str},
        ...
      ],
      "combat_pairs": [[n1, n2], ...]     # pairs that ever fought, sorted
    }

The expensive part — `build()` over all 53 saves — is what hung prod for
51 minutes in bash. The Python version finishes in well under a minute on
the same input. There's also `build_incremental()` that takes the existing
diplomacy.json and only processes turns past its `.turn` field; that's the
hot path on a normal turn change (just one new save to read).
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Iterable

from .freeciv_save import Save, Section, _strip_quotes


# Names used by the freeciv "barbarian" / "animal kingdom" pseudo-players.
# Matched on substring like the bash: "*arbarian*" plus exact "Lion" / "Pirates".
_BARBARIAN_NAME_HINTS = ("arbarian",)
_BARBARIAN_NAMES_EXACT = {"Lion", "Pirates"}
_BARBARIAN_NATION_HINTS = ("animal",)


def _is_barbarian(name: str | None, nation: str | None) -> bool:
    if name in _BARBARIAN_NAMES_EXACT:
        return True
    if name and any(h in name for h in _BARBARIAN_NAME_HINTS):
        return True
    if nation and any(h in nation.lower() for h in _BARBARIAN_NATION_HINTS):
        return True
    return False


def _pair_key(a: str, b: str) -> tuple[str, str]:
    """Sorted tuple, used as dict key for state-change diffs."""
    return (a, b) if a <= b else (b, a)


def extract_relationships(save: Save) -> list[dict]:
    """Per-save diplomacy snapshot. One entry per non-barbarian player pair
    that has met (i.e. status != "Never met"). Mirrors the bash
    extract_diplomacy() output for one save."""
    players = save.players()
    # Build index → (name, is_valid) map
    info: list[tuple[str | None, bool]] = []
    for p in players:
        name = p.get_str("name")
        nation = p.get_str("nation")
        info.append((name, not _is_barbarian(name, nation)))

    rels: list[dict] = []
    for i, p in enumerate(players):
        if not info[i][1]:
            continue
        dip = p.tables.get("diplstate")
        if dip is None:
            continue
        # Build column index lookup once per player
        h = dip.header
        idx_current = h.index("current")
        idx_closest = h.index("closest") if "closest" in h else idx_current
        idx_fct = h.index("first_contact_turn") if "first_contact_turn" in h else None
        idx_hrc = h.index("has_reason_to_cancel") if "has_reason_to_cancel" in h else None
        idx_emb = h.index("embassy") if "embassy" in h else None
        idx_sv = h.index("gives_shared_vision") if "gives_shared_vision" in h else None

        for j, row in enumerate(dip.rows):
            # Only emit each pair once: lower index "owns" the relationship.
            if j <= i:
                continue
            if not info[j][1]:
                continue
            status = _strip_quotes(row[idx_current])
            if status == "Never met":
                continue
            closest = _strip_quotes(row[idx_closest])
            # The bash quirk: status=War + closest=War means "just met, no
            # actual combat" → display as Contact. Real wars have a
            # ceasefire/peace/etc. as `closest`.
            display_status = "Contact" if (status == "War" and closest == "War") else status
            entry = {
                "players": [info[i][0], info[j][0]],
                "status": display_status,
                "closest": closest,
                "first_contact_turn": int(row[idx_fct]) if idx_fct is not None else 0,
                "has_reason_to_cancel": (
                    row[idx_hrc] != "0" if idx_hrc is not None else False
                ),
                "embassy": (
                    row[idx_emb].upper() == "TRUE" if idx_emb is not None else False
                ),
                "shared_vision": (
                    row[idx_sv].upper() == "TRUE" if idx_sv is not None else False
                ),
            }
            rels.append(entry)
    return rels


def extract_combat_pairs(save: Save) -> set[tuple[str, str]]:
    """Pairs of player names that engaged in combat on this turn.

    Combat events are paired by timestamp: an `E_UNIT_WIN_ATT` and
    `E_UNIT_LOST_DEF` (or similar) sharing the same timestamp belong to the
    same fight. The 8th column ("target") is a bitstring with one position
    per player slot — the bit that's set identifies which player saw that
    half of the event.
    """
    ec = save.sections.get("event_cache")
    if ec is None:
        return set()
    events = ec.tables.get("events")
    if events is None:
        return set()

    h = events.header
    try:
        idx_ts = h.index("timestamp")
        idx_event = h.index("event")
        idx_target = h.index("target")
    except ValueError:
        return set()

    # Map player index → name
    players = save.players()
    name_for_idx = {i: p.get_str("name") for i, p in enumerate(players)}

    pairs: set[tuple[str, str]] = set()
    prev_ts: str | None = None
    prev_pidx: int | None = None
    for row in events.rows:
        if len(row) <= max(idx_ts, idx_event, idx_target):
            continue
        evt = _strip_quotes(row[idx_event])
        if not (evt.startswith("E_UNIT_WIN_") or evt.startswith("E_UNIT_LOST_")):
            continue
        target_bits = _strip_quotes(row[idx_target])
        # Find the first set bit — that's the player index this event is for.
        pidx = target_bits.find("1")
        if pidx < 0:
            prev_ts = None
            prev_pidx = None
            continue
        ts = row[idx_ts]
        if ts == prev_ts and prev_pidx is not None and pidx != prev_pidx:
            n1 = name_for_idx.get(prev_pidx)
            n2 = name_for_idx.get(pidx)
            if n1 and n2:
                pairs.add(_pair_key(n1, n2))
            prev_ts = None
            prev_pidx = None
        else:
            prev_ts = ts
            prev_pidx = pidx
    return pairs


def _state_map(rels: list[dict]) -> dict[tuple[str, str], str]:
    """{(name1, name2) sorted: status}"""
    return {_pair_key(*r["players"]): r["status"] for r in rels}


def _diff_state_changes(
    turn: int,
    year: int,
    prev: dict[tuple[str, str], str],
    cur: dict[tuple[str, str], str],
) -> list[dict]:
    out: list[dict] = []
    # New + changed pairs
    for pair, cur_status in cur.items():
        prev_status = prev.get(pair, "Never met")
        if cur_status != prev_status:
            out.append({
                "turn": turn,
                "year": year,
                "players": [pair[0], pair[1]],
                "from": prev_status,
                "to": cur_status,
            })
    # Pairs that disappeared
    for pair, prev_status in prev.items():
        if pair not in cur:
            out.append({
                "turn": turn,
                "year": year,
                "players": [pair[0], pair[1]],
                "from": prev_status,
                "to": "Never met",
            })
    return out


def _upgrade_contact_to_war(
    rels: list[dict], combat_pairs: set[tuple[str, str]]
) -> list[dict]:
    """Pairs displayed as 'Contact' that actually fought get bumped to 'War'."""
    if not combat_pairs:
        return rels
    out = []
    for r in rels:
        if r["status"] == "Contact":
            key = _pair_key(*r["players"])
            if key in combat_pairs:
                r = {**r, "status": "War"}
        out.append(r)
    return out


def build(save_paths: Iterable[Path]) -> dict:
    """Full rebuild from scratch. Mirrors bash build_diplomacy().

    Always reprocesses every save. We tried an incremental version with a
    state-replay shortcut, but at ~1s per full rebuild the speedup wasn't
    worth the bug surface — the prev-state reconstruction was the kind of
    thing that goes subtly wrong months later. Self-healing > clever.
    """
    paths = sorted(
        save_paths,
        key=lambda p: int(p.stem.split("-")[-1].replace(".sav", "")),
    )
    if not paths:
        return {"turn": 0, "current": [], "events": [], "combat_pairs": []}

    prev_state: dict[tuple[str, str], str] = {}
    events: list[dict] = []
    combat_pairs: set[tuple[str, str]] = set()
    last_rels: list[dict] = []
    last_turn = 0
    for path in paths:
        save = Save.load(path)
        rels = extract_relationships(save)
        cur_state = _state_map(rels)
        events.extend(_diff_state_changes(save.turn, save.year, prev_state, cur_state))
        combat_pairs.update(extract_combat_pairs(save))
        prev_state = cur_state
        last_rels = rels
        last_turn = save.turn

    current = _upgrade_contact_to_war(last_rels, combat_pairs)
    return {
        "turn": last_turn,
        "current": current,
        "events": events,
        "combat_pairs": sorted([list(p) for p in combat_pairs]),
    }


def write(diplomacy: dict, out_path: Path) -> None:
    """Atomic write: write to .tmp then rename, so concurrent readers never
    see a partial file."""
    tmp = out_path.with_suffix(out_path.suffix + ".tmp")
    tmp.write_text(json.dumps(diplomacy, separators=(",", ":")))
    tmp.replace(out_path)
