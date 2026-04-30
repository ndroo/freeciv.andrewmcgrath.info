"""Build status.json — the file the website polls every few seconds.

The output schema (kept compatible with the bash version):

    {
      "meta": {generated_at, generated_epoch, server_host, server_port,
               join_form_url, game_version, ruleset},
      "game": {turn, year, year_display, server_status,
               registered_player_count, deadline_epoch, turn_timeout,
               save_mtime, turn_start_epoch, gazette_publishing},
      "players": [ {name, nation, score, cities, units, gold, government,
                    is_alive, rank, phase_done, is_connected,
                    connected_this_turn, missed_turns, total_turns}, ... ],
      "activity": {done_count, online_count, logged_in_count, total_players}
    }

The heavy lifting is in `build_player_rankings`. Live information
(phase_done from the snapshot save, connections from the freeciv log) is
passed in by the caller — those bits need to talk to the running server,
which is the bash wrapper's job.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path

from .diplomacy import _is_barbarian
from .freeciv_save import Save
from .history import _capitalize_nation


@dataclass
class StatusInputs:
    """Everything the status builder needs to produce status.json.

    Path fields can be omitted (None) — the builder substitutes the
    documented bash defaults so this class is also usable from tests."""

    save: Save
    save_path: Path | None = None
    attendance: dict = field(default_factory=dict)
    # Lower-cased player name → True
    phase_done_map: dict[str, bool] = field(default_factory=dict)
    connected_map: dict[str, bool] = field(default_factory=dict)
    connected_this_turn_map: dict[str, bool] = field(default_factory=dict)

    # game/meta fields
    server_status: str = "Online"
    registered_player_count: int = 0
    deadline_epoch: int = 0
    turn_timeout: int = 82800
    save_mtime: int = 0
    turn_start_epoch: int = 0
    gazette_publishing: int | None = None

    # constants surfaced in meta
    server_host: str = "freeciv.andrewmcgrath.info"
    server_port: int = 5556
    join_form_url: str = ""
    game_version: str = "3.2.4"
    ruleset: str = "civ2civ3"


def _year_display(year: int) -> str:
    if year < 0:
        return f"{-year} BC"
    return f"{year} AD"


def build_player_rankings(inputs: StatusInputs) -> dict:
    """Returns a dict with `players` (sorted) plus the activity counters
    (done/online/logged_in/total) so the caller can put both into the
    final status.json."""
    save = inputs.save
    raw_players = []
    for i, p in enumerate(save.players()):
        name = p.get_str("name")
        nation = p.get_str("nation")
        if name is None:
            continue
        if _is_barbarian(name, nation):
            continue
        score_sec = save.sections.get(f"score{i}")
        score = score_sec.get_int("total", 0) if score_sec else 0
        raw_players.append({
            "idx": i,
            "name": name,
            "nation": nation or "",
            "gold": p.get_int("gold", 0),
            "ncities": p.get_int("ncities", 0),
            "nunits": p.get_int("nunits", 0),
            "government": p.get_str("government_name") or "Despotism",
            "is_alive": p.get_bool("is_alive", True),
            "score": score or 0,
        })

    # Sort by score descending, stable on idx so identical scores keep a
    # deterministic order across runs.
    raw_players.sort(key=lambda x: (-x["score"], x["idx"]))

    done_count = online_count = logged_in_count = 0
    out_players: list[dict] = []
    for rank, p in enumerate(raw_players, 1):
        lower = p["name"].lower()
        is_done = inputs.phase_done_map.get(lower, False)
        is_connected = inputs.connected_map.get(lower, False)
        connected_this_turn = inputs.connected_this_turn_map.get(lower, False)

        # Mirror the bash counter logic: a player who's "done" is also
        # logged in (and online if currently connected). Otherwise:
        # currently connected counts as both online + logged in.
        # Otherwise: connected this turn counts only as logged in.
        phase_done_flag = False
        is_connected_flag = False
        connected_this_turn_flag = False
        if is_done:
            phase_done_flag = True
            done_count += 1
            logged_in_count += 1
            if is_connected:
                is_connected_flag = True
                online_count += 1
        elif is_connected:
            is_connected_flag = True
            online_count += 1
            logged_in_count += 1
        elif connected_this_turn:
            connected_this_turn_flag = True
            logged_in_count += 1

        att = inputs.attendance.get(p["name"], {})
        out_players.append({
            "name": p["name"],
            "nation": _capitalize_nation(p["nation"]),
            "score": p["score"],
            "cities": p["ncities"],
            "units": p["nunits"],
            "gold": p["gold"],
            "government": p["government"],
            "is_alive": bool(p["is_alive"]) if p["is_alive"] is not None else True,
            "rank": rank,
            "phase_done": phase_done_flag,
            "is_connected": is_connected_flag,
            "connected_this_turn": connected_this_turn_flag,
            "missed_turns": att.get("missed_turns", 0),
            "total_turns": att.get("total_turns", 0),
        })

    return {
        "players": out_players,
        "activity": {
            "done_count": done_count,
            "online_count": online_count,
            "logged_in_count": logged_in_count,
            "total_players": len(out_players),
        },
    }


def build(inputs: StatusInputs) -> dict:
    """Assemble the full status.json structure."""
    rankings = build_player_rankings(inputs)
    now = int(time.time())
    return {
        "meta": {
            "generated_at": time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(now)),
            "generated_epoch": now,
            "server_host": inputs.server_host,
            "server_port": inputs.server_port,
            "join_form_url": inputs.join_form_url,
            "game_version": inputs.game_version,
            "ruleset": inputs.ruleset,
        },
        "game": {
            "turn": inputs.save.turn,
            "year": inputs.save.year,
            "year_display": _year_display(inputs.save.year),
            "server_status": inputs.server_status,
            "registered_player_count": inputs.registered_player_count,
            "deadline_epoch": inputs.deadline_epoch,
            "turn_timeout": inputs.turn_timeout,
            "save_mtime": inputs.save_mtime,
            "turn_start_epoch": inputs.turn_start_epoch,
            "gazette_publishing": inputs.gazette_publishing,
        },
        "players": rankings["players"],
        "activity": rankings["activity"],
    }


def write(status: dict, out_path: Path) -> None:
    tmp = out_path.with_suffix(out_path.suffix + ".tmp")
    tmp.write_text(json.dumps(status, separators=(",", ":")))
    tmp.replace(out_path)
