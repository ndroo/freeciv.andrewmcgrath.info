"""Build history.json: append-only per-turn snapshot of player stats.

Each entry has the shape:

    {
      "turn": 53,
      "year": -1400,
      "players": {
        "Andrew": {
          "score": 63, "cities": 5, "units": 12, "gold": 33, "techs": 8,
          "nation": "Australian", "government": "Despotism", "is_alive": True,
          "unit_types": {"Settlers": 2, "Warriors": 4, ...},
          "wonders": 1, "culture": 1100, "pollution": 0, "literacy": 0,
          "population": 850, "landarea": 12, "units_built": 25,
          "units_killed": 4, "units_lost": 6, "spaceship": 0
        },
        ...
      },
      "public_events": [
        {"type": "wonder_built", "message": "..."},
        {"type": "city_founded",  "message": "..."},
        {"type": "government_change", "message": "..."}
      ]
    }
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Iterable

from .diplomacy import _is_barbarian
from .freeciv_save import Save, Section, _strip_quotes


# ----- per-save extraction ---------------------------------------------


def _score_section(save: Save, idx: int) -> Section | None:
    return save.sections.get(f"score{idx}")


def _research_techs_for_player(save: Save, idx: int) -> int:
    """Count of techs for player idx, read from the [research] table."""
    research = save.sections.get("research")
    if research is None:
        return 0
    # The [research] section stores rows directly as scalar key/value pairs
    # in the format `<idx>,<future>,<techs>,...` BUT the freeciv save
    # actually puts research as a `r=` table in some versions and as
    # untagged numeric-keyed lines in others. Check both.
    table = research.tables.get("r")
    if table is not None and "techs" in table.header and "number" in table.header:
        try:
            num_idx = table.header.index("number")
            tech_idx = table.header.index("techs")
            for row in table.rows:
                if row[num_idx] == str(idx):
                    return int(row[tech_idx])
        except (ValueError, IndexError):
            pass
    # Fallback: look for raw scalar lines like `0,0,8,...`
    for k, v in research.scalars.items():
        if k.startswith(f"{idx},"):
            parts = (k + "," + v).split(",")
            try:
                return int(parts[2])
            except (ValueError, IndexError):
                pass
    return 0


def _unit_type_counts(player: Section) -> dict[str, int]:
    """Count units by their `type_by_name` column from the player's u={...}."""
    table = player.tables.get("u")
    if table is None:
        return {}
    if "type_by_name" not in table.header:
        return {}
    type_idx = table.header.index("type_by_name")
    counts: dict[str, int] = {}
    for row in table.rows:
        if type_idx >= len(row):
            continue
        name = _strip_quotes(row[type_idx])
        if not name:
            continue
        counts[name] = counts.get(name, 0) + 1
    return counts


def _capitalize_nation(nation: str) -> str:
    """Match the bash `${var^}` — capitalize first character only."""
    if not nation:
        return nation
    return nation[0].upper() + nation[1:]


def build_history_entry(save: Save) -> dict:
    """One entry in history.json for the given save."""
    players_out: dict[str, dict] = {}
    for i, p in enumerate(save.players()):
        name = p.get_str("name")
        nation = p.get_str("nation")
        if name is None:
            continue
        if _is_barbarian(name, nation):
            continue
        score_sec = _score_section(save, i)
        sc = lambda key, default=0: (
            score_sec.get_int(key, default) if score_sec else default
        )
        players_out[name] = {
            "score": sc("total"),
            "cities": p.get_int("ncities", 0),
            "units": p.get_int("nunits", 0),
            "gold": p.get_int("gold", 0),
            "techs": _research_techs_for_player(save, i),
            "nation": _capitalize_nation(nation or ""),
            "government": p.get_str("government_name") or "Despotism",
            "is_alive": p.get_bool("is_alive", True),
            "unit_types": _unit_type_counts(p),
            "wonders": sc("wonders"),
            "culture": sc("culture"),
            "pollution": sc("pollution"),
            "literacy": sc("literacy"),
            "population": sc("population"),
            "landarea": sc("landarea"),
            "units_built": sc("units_built"),
            "units_killed": sc("units_killed"),
            "units_lost": sc("units_lost"),
            "spaceship": sc("spaceship"),
        }
    return {
        "turn": save.turn,
        "year": save.year,
        "players": players_out,
        "public_events": extract_public_events(save),
    }


# ----- public events ---------------------------------------------------

# These messages are visible to ALL players in-game so it's safe to surface
# them in history.json. Keep this list in sync with the bash version.
_PUBLIC_EVENT_TYPES = {
    "E_WONDER_BUILD": "wonder_built",
    "E_REVOLT_DONE": "government_change",
    "E_CITY_BUILD": "city_founded",
}


def extract_public_events(save: Save) -> list[dict]:
    ec = save.sections.get("event_cache")
    if ec is None:
        return []
    events_table = ec.tables.get("events")
    if events_table is None:
        return []
    h = events_table.header
    try:
        idx_event = h.index("event")
        idx_target = h.index("target")
        idx_msg = h.index("message")
    except ValueError:
        return []

    out: list[dict] = []
    for row in events_table.rows:
        if len(row) <= max(idx_event, idx_target, idx_msg):
            continue
        evt = _strip_quotes(row[idx_event])
        kind = _PUBLIC_EVENT_TYPES.get(evt)
        if kind is None:
            continue
        # E_CITY_BUILD: only public when target is "All". Wonders and
        # government changes are inherently public so we include those
        # regardless of target.
        if evt == "E_CITY_BUILD":
            target = _strip_quotes(row[idx_target])
            if target != "All":
                continue
        out.append({"type": kind, "message": _strip_quotes(row[idx_msg])})
    return out


# ----- top-level rebuild -----------------------------------------------


def _turn_from_path(p: Path) -> int:
    return int(p.stem.split("-")[-1].replace(".sav", ""))


def build(save_paths: Iterable[Path]) -> list[dict]:
    """Full rebuild from scratch. We deliberately do not have an
    incremental version — a full rebuild over 53 saves is ~1s, and the
    self-healing property of "always reread everything" eliminates a
    whole class of staleness bugs."""
    paths = sorted(save_paths, key=_turn_from_path)
    return [build_history_entry(Save.load(p)) for p in paths]


def write(history: list[dict], out_path: Path) -> None:
    tmp = out_path.with_suffix(out_path.suffix + ".tmp")
    tmp.write_text(json.dumps(history, separators=(",", ":")))
    tmp.replace(out_path)
