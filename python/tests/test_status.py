"""Tests for the status.json builder.

The builder takes a snapshot save + attendance + a few live-status maps
(phase_done, connected, connected_this_turn) that the bash wrapper
populates from the running freeciv server. Those bits aren't exercised
here — we feed them in directly to verify the JSON shape and the
ranking/counter logic.
"""

import json
from pathlib import Path

from lib.freeciv_save import Save
from lib.status import StatusInputs, build, build_player_rankings, write


def test_build_produces_full_status_shape(latest_save: Path):
    s = Save.load(latest_save)
    out = build(StatusInputs(save=s))
    assert set(out.keys()) == {"meta", "game", "players", "activity"}
    assert out["game"]["turn"] == 53
    assert out["game"]["year"] == -1400
    assert out["game"]["year_display"] == "1400 BC"
    assert isinstance(out["players"], list)


def test_build_year_display_handles_ad(tmp_path: Path):
    """Smoke-test with year 0 / positive years using the same save but a
    synthetic year override is overkill — just trust the test on the BC
    case and exercise the helper directly."""
    from lib.status import _year_display
    assert _year_display(-1400) == "1400 BC"
    assert _year_display(0) == "0 AD"
    assert _year_display(1500) == "1500 AD"


def test_player_rankings_sorted_by_score_desc(latest_save: Path):
    s = Save.load(latest_save)
    out = build(StatusInputs(save=s))
    scores = [p["score"] for p in out["players"]]
    assert scores == sorted(scores, reverse=True)


def test_player_rankings_have_consecutive_ranks(latest_save: Path):
    s = Save.load(latest_save)
    out = build(StatusInputs(save=s))
    ranks = [p["rank"] for p in out["players"]]
    assert ranks == list(range(1, len(ranks) + 1))


def test_player_rankings_drop_barbarians(latest_save: Path):
    s = Save.load(latest_save)
    out = build(StatusInputs(save=s))
    names = {p["name"] for p in out["players"]}
    assert "Lion" not in names


def test_attendance_data_propagates(latest_save: Path):
    s = Save.load(latest_save)
    attendance = {
        "Andrew": {"missed_turns": 3, "total_turns": 52, "missed": [1, 5, 12]},
        "Shazow": {"missed_turns": 0, "total_turns": 52, "missed": []},
    }
    out = build(StatusInputs(save=s, attendance=attendance))
    by_name = {p["name"]: p for p in out["players"]}
    assert by_name["Andrew"]["missed_turns"] == 3
    assert by_name["Andrew"]["total_turns"] == 52
    assert by_name["Shazow"]["missed_turns"] == 0


def test_phase_done_drives_done_count(latest_save: Path):
    s = Save.load(latest_save)
    out = build(StatusInputs(
        save=s,
        phase_done_map={"andrew": True, "shazow": True, "hyfen": True},
    ))
    assert out["activity"]["done_count"] == 3
    by_name = {p["name"]: p for p in out["players"]}
    assert by_name["Andrew"]["phase_done"] is True
    assert by_name["Hyfen"]["phase_done"] is True
    # An undeclared player should be False, not missing.
    assert by_name["Jess"]["phase_done"] is False


def test_done_player_also_counts_as_logged_in(latest_save: Path):
    """Bash invariant: a done player is implicitly logged in (we know
    they connected to click Turn Done)."""
    s = Save.load(latest_save)
    out = build(StatusInputs(
        save=s,
        phase_done_map={"andrew": True},
    ))
    # done=1, online=0, logged_in=1 (because done implies logged in).
    assert out["activity"]["done_count"] == 1
    assert out["activity"]["online_count"] == 0
    assert out["activity"]["logged_in_count"] == 1


def test_connected_player_counts_as_online_and_logged_in(latest_save: Path):
    s = Save.load(latest_save)
    out = build(StatusInputs(
        save=s,
        connected_map={"andrew": True},
    ))
    assert out["activity"]["online_count"] == 1
    assert out["activity"]["logged_in_count"] == 1


def test_connected_this_turn_only_counts_as_logged_in(latest_save: Path):
    s = Save.load(latest_save)
    out = build(StatusInputs(
        save=s,
        connected_this_turn_map={"andrew": True},
    ))
    assert out["activity"]["online_count"] == 0
    assert out["activity"]["logged_in_count"] == 1


def test_total_players_counts_only_real_players(latest_save: Path):
    s = Save.load(latest_save)
    out = build(StatusInputs(save=s))
    # 16 humans (Lion is filtered out).
    assert out["activity"]["total_players"] == 16


def test_meta_fields_passthrough(latest_save: Path):
    s = Save.load(latest_save)
    out = build(StatusInputs(
        save=s,
        server_host="example.test",
        server_port=12345,
        join_form_url="https://example.test/join",
        game_version="9.9.9",
        ruleset="custom",
    ))
    assert out["meta"]["server_host"] == "example.test"
    assert out["meta"]["server_port"] == 12345
    assert out["meta"]["join_form_url"] == "https://example.test/join"
    assert out["meta"]["game_version"] == "9.9.9"
    assert out["meta"]["ruleset"] == "custom"


def test_write_is_atomic(tmp_path: Path, latest_save: Path):
    s = Save.load(latest_save)
    data = build(StatusInputs(save=s))
    out_path = tmp_path / "status.json"
    write(data, out_path)
    assert out_path.exists()
    loaded = json.loads(out_path.read_text())
    assert loaded["game"]["turn"] == 53
    assert not (tmp_path / "status.json.tmp").exists()
