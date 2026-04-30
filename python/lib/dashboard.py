"""Per-player dashboard JSON files.

Each file lives at `<save_dir>/dashboard/<lowercase-username>.json` and has:

    {
      "player": "andrew",
      "nation": "Australian",
      "current": {
        "name": ..., "nation": ..., "government": ..., "gold": ...,
        "score": ..., "is_alive": True,
        "techs_count": ..., "researching": ..., "goal": ...,
        "techs": [name, ...],
        "cities": [{name, size, building, improvements: [...], turn_founded}, ...],
        "units": [{id, type, born, hp, veteran}, ...],
        "unit_types": {type: count, ...},
        "diplomacy": [{player, nation, status, first_contact_turn}, ...]
      },
      "timeline": [
        {"turn": N, "year": "1500 BC", "events": [
          {"type": "unit_built", "detail": "Settlers built"},
          {"type": "city_founded", "detail": "Founded Ottawhere"},
          {"type": "tech_researched", "detail": "Learned Pottery"},
          ...
        ]},
        ...
      ]
    }

The bash version takes 9-24 minutes per run because it forks `jq` thousands
of times in nested loops. Python with native dict diffs finishes in seconds.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Iterable

from .diplomacy import _is_barbarian
from .freeciv_save import Save, Section, _strip_quotes


# ----- per-save extraction ---------------------------------------------


def _decode_bitmask(bitmask: str, vector: list[str]) -> list[str]:
    """For each bit set in `bitmask`, return the name at that index in
    `vector`. Drops "A_NONE" and "" (placeholder entries)."""
    out = []
    for i, ch in enumerate(bitmask):
        if i >= len(vector):
            break
        if ch == "1":
            name = vector[i]
            if name and name != "A_NONE":
                out.append(name)
    return out


def _research_for_player(
    save: Save, player_idx: int, tech_vector: list[str]
) -> dict:
    """Pulls techs_count, currently-researching tech, goal, and the list
    of completed techs (decoded from the player's `done` bitmask)."""
    research = save.sections.get("research")
    out = {
        "techs_count": 0,
        "researching": "",
        "goal": "",
        "techs": [],
    }
    if research is None:
        return out
    table = research.tables.get("r")
    if table is None:
        return out
    h = table.header
    if "number" not in h:
        return out
    num_idx = h.index("number")
    techs_idx = h.index("techs") if "techs" in h else None
    goal_idx = h.index("goal_name") if "goal_name" in h else None
    now_idx = h.index("now_name") if "now_name" in h else None
    done_idx = h.index("done") if "done" in h else None

    for row in table.rows:
        if row[num_idx] != str(player_idx):
            continue
        if techs_idx is not None:
            try:
                out["techs_count"] = int(row[techs_idx])
            except (ValueError, IndexError):
                pass
        if goal_idx is not None and goal_idx < len(row):
            out["goal"] = _strip_quotes(row[goal_idx])
        if now_idx is not None and now_idx < len(row):
            out["researching"] = _strip_quotes(row[now_idx])
        if done_idx is not None and done_idx < len(row):
            out["techs"] = _decode_bitmask(_strip_quotes(row[done_idx]), tech_vector)
        break
    return out


def _cities_for_player(p: Section, improvement_vector: list[str]) -> list[dict]:
    table = p.tables.get("c")
    if table is None:
        return []
    h = table.header
    idx_name = h.index("name") if "name" in h else None
    idx_size = h.index("size") if "size" in h else None
    idx_build = h.index("currently_building_name") if "currently_building_name" in h else None
    idx_imp = h.index("improvements") if "improvements" in h else None
    idx_founded = h.index("turn_founded") if "turn_founded" in h else None

    out = []
    for row in table.rows:
        def _get(idx, default=""):
            if idx is None or idx >= len(row):
                return default
            return _strip_quotes(row[idx])
        try:
            size = int(_get(idx_size, "0") or "0")
        except ValueError:
            size = 0
        try:
            founded = int(_get(idx_founded, "0") or "0")
        except ValueError:
            founded = 0
        bitmask = _get(idx_imp, "")
        out.append({
            "name": _get(idx_name),
            "size": size,
            "building": _get(idx_build),
            "improvements": _decode_bitmask(bitmask, improvement_vector),
            "turn_founded": founded,
        })
    return out


def _units_for_player(p: Section) -> tuple[list[dict], dict[str, int]]:
    """Returns (units list, unit_types count map)."""
    table = p.tables.get("u")
    if table is None:
        return [], {}
    h = table.header
    idx_id = h.index("id") if "id" in h else None
    idx_type = h.index("type_by_name") if "type_by_name" in h else None
    idx_born = h.index("born") if "born" in h else None
    idx_hp = h.index("hp") if "hp" in h else None
    idx_vet = h.index("veteran") if "veteran" in h else None

    units: list[dict] = []
    counts: dict[str, int] = {}
    for row in table.rows:
        def _get(idx, default=""):
            if idx is None or idx >= len(row):
                return default
            return row[idx]
        utype = _strip_quotes(_get(idx_type))
        if not utype:
            continue
        try:
            uid = int(_get(idx_id, "0") or "0")
            born = int(_get(idx_born, "0") or "0")
            hp = int(_get(idx_hp, "0") or "0")
            vet = int(_get(idx_vet, "0") or "0")
        except ValueError:
            continue
        units.append({
            "id": uid,
            "type": utype,
            "born": born,
            "hp": hp,
            "veteran": vet > 0,
        })
        counts[utype] = counts.get(utype, 0) + 1
    return units, counts


def _diplomacy_for_player(save: Save, player_idx: int) -> list[dict]:
    players = save.players()
    if player_idx >= len(players):
        return []
    me = players[player_idx]
    dip = me.tables.get("diplstate")
    if dip is None:
        return []
    h = dip.header
    idx_cur = h.index("current") if "current" in h else None
    idx_fct = h.index("first_contact_turn") if "first_contact_turn" in h else None
    if idx_cur is None:
        return []

    out = []
    for j, row in enumerate(dip.rows):
        if j == player_idx:
            continue
        if j >= len(players):
            break
        status = _strip_quotes(row[idx_cur])
        if status == "Never met":
            continue
        try:
            fct = int(row[idx_fct]) if idx_fct is not None else 0
        except (ValueError, IndexError):
            fct = 0
        other = players[j]
        out.append({
            "player": other.get_str("name") or "",
            "nation": other.get_str("nation") or "",
            "status": status,
            "first_contact_turn": fct,
        })
    return out


def extract_player_state(
    save: Save, username: str, *, _vectors: tuple[list[str], list[str]] | None = None
) -> dict | None:
    """Build the `current` block for one player from one save.

    Matches usernames case-insensitively and picks the first hit, like the
    bash `grep -i 'username="..."'`. Returns None if the player isn't
    present in this save (e.g. they haven't joined yet on early turns).
    """
    if _vectors is None:
        savefile = save.sections.get("savefile")
        if savefile is None:
            return None
        improvement_vector = savefile.get_vector("improvement_vector")
        tech_vector = savefile.get_vector("technology_vector")
    else:
        improvement_vector, tech_vector = _vectors

    target = username.lower()
    for i, p in enumerate(save.players()):
        u = p.get_str("username") or ""
        if u.lower() != target:
            continue
        units, unit_types = _units_for_player(p)
        research = _research_for_player(save, i, tech_vector)
        return {
            "name": p.get_str("name") or "",
            "nation": p.get_str("nation") or "",
            "government": p.get_str("government_name") or "Despotism",
            "gold": p.get_int("gold", 0),
            "score": (
                save.sections.get(f"score{i}").get_int("total", 0)
                if save.sections.get(f"score{i}")
                else 0
            ),
            "is_alive": bool(p.get_bool("is_alive", True)),
            "techs_count": research["techs_count"],
            "researching": research["researching"],
            "goal": research["goal"],
            "techs": research["techs"],
            "cities": _cities_for_player(p, improvement_vector),
            "units": units,
            "unit_types": unit_types,
            "diplomacy": _diplomacy_for_player(save, i),
        }
    return None


# ----- per-turn diff ---------------------------------------------------


def diff_states(prev: dict, curr: dict) -> list[dict]:
    """Compare two `current`-shaped state dicts and emit timeline events."""
    events: list[dict] = []

    # Units built/lost — by id.
    prev_unit_ids = {u["id"]: u for u in prev["units"]}
    curr_unit_ids = {u["id"]: u for u in curr["units"]}
    for uid, u in curr_unit_ids.items():
        if uid not in prev_unit_ids:
            events.append({"type": "unit_built", "detail": f"{u['type']} built"})
    for uid, u in prev_unit_ids.items():
        if uid not in curr_unit_ids:
            events.append({"type": "unit_lost", "detail": f"{u['type']} lost"})

    # Cities founded — by name (matches bash).
    prev_city_names = {c["name"] for c in prev["cities"]}
    curr_city_names = {c["name"] for c in curr["cities"]}
    for name in curr_city_names - prev_city_names:
        events.append({"type": "city_founded", "detail": f"Founded {name}"})

    # Buildings completed — per matching city, diff improvement lists.
    prev_city_imps = {c["name"]: set(c["improvements"]) for c in prev["cities"]}
    for c in curr["cities"]:
        if c["name"] not in prev_city_imps:
            continue
        new_buildings = set(c["improvements"]) - prev_city_imps[c["name"]]
        for b in new_buildings:
            events.append({
                "type": "building_completed",
                "detail": f"{b} completed in {c['name']}",
            })

    # Techs learned.
    prev_techs = set(prev["techs"])
    for t in curr["techs"]:
        if t not in prev_techs:
            events.append({"type": "tech_researched", "detail": f"Learned {t}"})

    # Government change.
    if prev["government"] != curr["government"]:
        events.append({
            "type": "government_changed",
            "detail": f"Changed from {prev['government']} to {curr['government']}",
        })

    # Diplomacy changes — first contact + status flips.
    prev_diplo = {d["player"]: d for d in prev["diplomacy"]}
    for d in curr["diplomacy"]:
        prev_d = prev_diplo.get(d["player"])
        if prev_d is None:
            events.append({
                "type": "diplomacy_changed",
                "detail": f"First contact with {d['player']} ({d['nation']})",
            })
        elif prev_d["status"] != d["status"]:
            events.append({
                "type": "diplomacy_changed",
                "detail": f"{d['status']} with {d['player']} ({d['nation']})",
            })

    # Score change.
    delta = curr["score"] - prev["score"]
    if delta != 0:
        sign = "+" if delta > 0 else ""
        events.append({
            "type": "score_change",
            "detail": f"Score: {prev['score']} → {curr['score']} ({sign}{delta})",
        })

    return events


# ----- top-level orchestration -----------------------------------------


def _turn_from_path(p: Path) -> int:
    return int(p.stem.split("-")[-1].replace(".sav", ""))


def _year_display(year: int) -> str:
    if year < 0:
        return f"{-year} BC"
    return f"{year} AD"


def _player_usernames(save: Save) -> list[str]:
    """Lowercase usernames of all non-barbarian human players."""
    out: list[str] = []
    for p in save.players():
        username = p.get_str("username") or ""
        nation = p.get_str("nation")
        name = p.get_str("name")
        if not username:
            continue
        if username.lower() in ("ranked_unassigned", "unassigned"):
            continue
        if _is_barbarian(name, nation):
            continue
        out.append(username.lower())
    # Stable order, dedup.
    return sorted(set(out))


def build_dashboards(save_paths: Iterable[Path]) -> dict[str, dict]:
    """Compute per-player dashboards for every save in `save_paths`.

    Returns {lowercase_username: dashboard_dict}.
    """
    paths = sorted(save_paths, key=_turn_from_path)
    if not paths:
        return {}

    # Pre-load all saves once (much cheaper than reopening per player).
    saves: list[tuple[int, Save]] = []
    for path in paths:
        try:
            saves.append((_turn_from_path(path), Save.load(path)))
        except (OSError, ValueError):
            continue
    if not saves:
        return {}

    # Vectors come from the savefile section — they're stable across the
    # game (built into the ruleset at game-start), so reading from the
    # earliest save is fine.
    first_savefile = saves[0][1].sections.get("savefile")
    improvement_vector = (
        first_savefile.get_vector("improvement_vector") if first_savefile else []
    )
    tech_vector = (
        first_savefile.get_vector("technology_vector") if first_savefile else []
    )
    vectors = (improvement_vector, tech_vector)

    # Player roster comes from the latest save.
    latest_save = saves[-1][1]
    usernames = _player_usernames(latest_save)

    out: dict[str, dict] = {}
    for username in usernames:
        prev_state: dict | None = None
        timeline: list[dict] = []
        last_state: dict | None = None
        last_nation = ""
        for turn, save in saves:
            state = extract_player_state(save, username, _vectors=vectors)
            if state is None:
                continue
            year_display = _year_display(save.year)
            events = diff_states(prev_state, state) if prev_state is not None else []
            timeline.append({"turn": turn, "year": year_display, "events": events})
            prev_state = state
            last_state = state
            last_nation = state["nation"]

        if last_state is None:
            continue
        out[username] = {
            "player": username,
            "nation": last_nation,
            "current": last_state,
            "timeline": timeline,
        }
    return out


def write_all(dashboards: dict[str, dict], out_dir: Path) -> None:
    """Atomic per-file write."""
    out_dir.mkdir(parents=True, exist_ok=True)
    for username, data in dashboards.items():
        out_path = out_dir / f"{username}.json"
        tmp = out_path.with_suffix(out_path.suffix + ".tmp")
        tmp.write_text(json.dumps(data, separators=(",", ":")))
        tmp.replace(out_path)
