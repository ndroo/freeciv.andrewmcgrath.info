"""Build attendance.json: per-player count of total/missed turns.

For each completed turn (i.e. every save except the in-progress current
one), we look at every non-barbarian, alive player and check whether
`phase_done=TRUE`. If not, that player missed the turn.

Output schema:

    {
      "PlayerName": {
        "missed_turns": int,
        "total_turns": int,
        "missed":  [3, 7, 12]    # turn numbers they missed
      },
      ...
    }

Like diplomacy, this supports incremental updates so the next-turn cron
doesn't replay every save from turn 1.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Iterable

from .diplomacy import _is_barbarian
from .freeciv_save import Save


def _turn_from_path(p: Path) -> int:
    return int(p.stem.split("-")[-1].replace(".sav", ""))


def attendance_for_save(save: Save) -> dict[str, bool]:
    """Per-player phase_done snapshot for one save.

    Returns {name: did_complete_turn}. Skips barbarians and dead players —
    they don't contribute to attendance scoring.
    """
    out: dict[str, bool] = {}
    for p in save.players():
        name = p.get_str("name")
        nation = p.get_str("nation")
        if name is None:
            continue
        if _is_barbarian(name, nation):
            continue
        if p.get_bool("is_alive") is False:
            continue
        out[name] = bool(p.get_bool("phase_done"))
    return out


def build(save_paths: Iterable[Path]) -> dict:
    """Full rebuild from scratch.

    Mirrors the bash convention: the LATEST save is the in-progress turn
    and is excluded — only completed turns count toward attendance. We
    don't bother with an incremental path; full rebuild is fast and
    avoids the staleness bugs that incremental versions accumulate.
    """
    paths = sorted(save_paths, key=_turn_from_path)
    if len(paths) <= 1:
        return {}
    completed = paths[:-1]

    attendance: dict[str, dict] = {}
    for path in completed:
        save = Save.load(path)
        turn = save.turn
        for name, did in attendance_for_save(save).items():
            entry = attendance.setdefault(
                name, {"missed_turns": 0, "total_turns": 0, "missed": []}
            )
            entry["total_turns"] += 1
            if not did:
                entry["missed_turns"] += 1
                entry["missed"].append(turn)
    return attendance


def write(attendance: dict, out_path: Path) -> None:
    tmp = out_path.with_suffix(out_path.suffix + ".tmp")
    tmp.write_text(json.dumps(attendance, separators=(",", ":")))
    tmp.replace(out_path)
