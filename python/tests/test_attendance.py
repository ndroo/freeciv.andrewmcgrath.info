"""Tests + benchmark for the attendance builder."""

import time
from pathlib import Path

from lib import attendance
from lib.freeciv_save import Save


def test_attendance_for_save_skips_barbarians(latest_save: Path):
    s = Save.load(latest_save)
    out = attendance.attendance_for_save(s)
    assert "Lion" not in out  # barbarian


def test_attendance_for_save_returns_phase_done_per_player(latest_save: Path):
    # Turn 53 fixture: Shazow phase_done=TRUE, Hyfen phase_done=FALSE
    s = Save.load(latest_save)
    out = attendance.attendance_for_save(s)
    assert out["Shazow"] is True
    assert out["Hyfen"] is False


def test_full_build_excludes_in_progress_turn(all_saves: list[Path]):
    """The latest save is the in-progress turn — every player should have
    `total_turns == 52` (we have saves 1-53, so 52 completed)."""
    out = attendance.build(all_saves)
    # All known players should be present.
    expected_players = {"Andrew", "Hyfen", "Shazow", "Jess"}
    assert expected_players.issubset(out.keys())
    # max total_turns is 52
    max_total = max(e["total_turns"] for e in out.values())
    assert max_total == 52


def test_full_build_records_missed_turns(all_saves: list[Path]):
    out = attendance.build(all_saves)
    # missed entry length should equal missed_turns count.
    for name, entry in out.items():
        assert len(entry["missed"]) == entry["missed_turns"], name
        # Missed turns should be sorted ascending (we append in order).
        assert entry["missed"] == sorted(entry["missed"])


def test_full_build_finishes_quickly(all_saves: list[Path]):
    """Same benchmark concern as diplomacy. Bash version was painful."""
    start = time.monotonic()
    out = attendance.build(all_saves)
    elapsed = time.monotonic() - start
    print(f"\n[benchmark] full attendance build over {len(all_saves)} saves: {elapsed:.2f}s")
    assert len(out) > 0
    assert elapsed < 30.0
