"""Tests + benchmark for history.json builder."""

import time
from pathlib import Path

from lib import history
from lib.freeciv_save import Save


# ----- per-save extraction ---------------------------------------------


def test_history_entry_has_top_level_fields(latest_save: Path):
    s = Save.load(latest_save)
    e = history.build_history_entry(s)
    assert e["turn"] == 53
    assert e["year"] == -1400
    assert isinstance(e["players"], dict)
    assert isinstance(e["public_events"], list)


def test_history_entry_includes_known_player(latest_save: Path):
    s = Save.load(latest_save)
    e = history.build_history_entry(s)
    shazow = e["players"]["Shazow"]
    assert shazow["nation"] == "Canadian"
    assert shazow["gold"] == 91
    assert shazow["cities"] == 4
    assert shazow["units"] == 13
    assert shazow["government"] == "Despotism"
    assert shazow["is_alive"] is True


def test_history_entry_drops_barbarians(latest_save: Path):
    s = Save.load(latest_save)
    e = history.build_history_entry(s)
    assert "Lion" not in e["players"]


def test_unit_types_count_matches_nunits(latest_save: Path):
    """Sum of unit_types should equal nunits — sanity check the counter."""
    s = Save.load(latest_save)
    e = history.build_history_entry(s)
    for name, p in e["players"].items():
        if not p["is_alive"]:
            continue
        total = sum(p["unit_types"].values())
        assert total == p["units"], f"{name}: unit_types sum={total} but units={p['units']}"


def test_score_section_fields_present(latest_save: Path):
    s = Save.load(latest_save)
    e = history.build_history_entry(s)
    shazow = e["players"]["Shazow"]
    # All score fields should be ints (not None).
    for key in (
        "score", "wonders", "culture", "pollution", "literacy",
        "population", "landarea", "units_built", "units_killed",
        "units_lost", "spaceship",
    ):
        assert isinstance(shazow[key], int), f"{key} is {type(shazow[key])}"


# ----- full rebuild ----------------------------------------------------


def test_full_build_one_entry_per_save(all_saves: list[Path]):
    out = history.build(all_saves)
    assert len(out) == len(all_saves)
    turns = [e["turn"] for e in out]
    assert turns == sorted(turns)
    assert turns[0] == 1
    assert turns[-1] == 53


def test_full_build_finishes_quickly(all_saves: list[Path]):
    start = time.monotonic()
    out = history.build(all_saves)
    elapsed = time.monotonic() - start
    print(f"\n[benchmark] full history build over {len(all_saves)} saves: {elapsed:.2f}s")
    assert len(out) == 53
    assert elapsed < 60.0
