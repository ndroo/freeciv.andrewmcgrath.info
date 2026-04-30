"""Tests + benchmark for the dashboard builder.

The bash version of this script consistently takes 9–24 minutes per turn.
The python rewrite over the same 53 saves should finish in well under a
minute. That's the headline number this test exists to defend.
"""

import time
from pathlib import Path

from lib import dashboard
from lib.freeciv_save import Save


# ----- per-save extraction ---------------------------------------------


def test_extract_player_state_returns_known_fields(latest_save: Path):
    s = Save.load(latest_save)
    state = dashboard.extract_player_state(s, "andrew")
    assert state is not None
    assert state["name"] == "Andrew"
    assert state["nation"] == "Australian"
    assert isinstance(state["cities"], list)
    assert isinstance(state["units"], list)
    assert isinstance(state["techs"], list)
    assert isinstance(state["diplomacy"], list)


def test_extract_player_state_case_insensitive_username(latest_save: Path):
    s = Save.load(latest_save)
    a = dashboard.extract_player_state(s, "andrew")
    b = dashboard.extract_player_state(s, "ANDREW")
    c = dashboard.extract_player_state(s, "Andrew")
    assert a == b == c


def test_extract_player_state_returns_none_for_unknown(latest_save: Path):
    s = Save.load(latest_save)
    assert dashboard.extract_player_state(s, "nobody-exists") is None


def test_extract_player_state_unit_types_match_units(latest_save: Path):
    s = Save.load(latest_save)
    state = dashboard.extract_player_state(s, "andrew")
    assert sum(state["unit_types"].values()) == len(state["units"])


def test_extract_player_state_diplomacy_excludes_self(latest_save: Path):
    s = Save.load(latest_save)
    state = dashboard.extract_player_state(s, "andrew")
    assert "Andrew" not in {d["player"] for d in state["diplomacy"]}


def test_cities_decode_improvements(latest_save: Path):
    """Improvements bitmask should expand to readable building names like
    'Granary' or 'City Walls', not raw bits."""
    s = Save.load(latest_save)
    state = dashboard.extract_player_state(s, "shazow")
    assert state is not None
    # Shazow has at least one city with at least one improvement.
    any_imps = [imp for c in state["cities"] for imp in c["improvements"]]
    if any_imps:
        # If anyone has any improvements, they should be human-readable.
        for name in any_imps:
            assert name and name != "A_NONE"


# ----- diff -------------------------------------------------------------


def test_diff_no_change_returns_no_events():
    state = {
        "name": "x", "nation": "y", "government": "Despotism",
        "gold": 10, "score": 5, "is_alive": True,
        "techs_count": 0, "researching": "", "goal": "", "techs": [],
        "cities": [], "units": [], "unit_types": {}, "diplomacy": [],
    }
    assert dashboard.diff_states(state, state) == []


def test_diff_emits_unit_built():
    base = {
        "name": "x", "nation": "y", "government": "Despotism",
        "gold": 10, "score": 5, "is_alive": True,
        "techs_count": 0, "researching": "", "goal": "", "techs": [],
        "cities": [], "units": [], "unit_types": {}, "diplomacy": [],
    }
    after = {**base, "units": [{"id": 1, "type": "Settlers", "born": 1, "hp": 20, "veteran": False}]}
    events = dashboard.diff_states(base, after)
    assert {"type": "unit_built", "detail": "Settlers built"} in events


def test_diff_emits_city_founded_and_tech_and_government():
    base = {
        "name": "x", "nation": "y", "government": "Despotism",
        "gold": 10, "score": 5, "is_alive": True,
        "techs_count": 0, "researching": "", "goal": "", "techs": ["Pottery"],
        "cities": [], "units": [], "unit_types": {}, "diplomacy": [],
    }
    after = {
        **base,
        "government": "Monarchy",
        "techs": ["Pottery", "Bronze Working"],
        "cities": [{"name": "Sydney", "size": 1, "building": "Warriors",
                    "improvements": [], "turn_founded": 5}],
    }
    events = dashboard.diff_states(base, after)
    types = [e["type"] for e in events]
    assert "city_founded" in types
    assert "tech_researched" in types
    assert "government_changed" in types


def test_diff_emits_diplomacy_first_contact_and_change():
    base = {
        "name": "x", "nation": "y", "government": "Despotism",
        "gold": 10, "score": 5, "is_alive": True,
        "techs_count": 0, "researching": "", "goal": "", "techs": [],
        "cities": [], "units": [], "unit_types": {}, "diplomacy": [
            {"player": "Andrew", "nation": "Australian", "status": "War",
             "first_contact_turn": 10},
        ],
    }
    after = {
        **base,
        "diplomacy": [
            {"player": "Andrew", "nation": "Australian", "status": "Peace",
             "first_contact_turn": 10},
            {"player": "Hyfen", "nation": "Dutch", "status": "Contact",
             "first_contact_turn": 50},
        ],
    }
    events = dashboard.diff_states(base, after)
    details = {e["detail"] for e in events}
    assert "Peace with Andrew (Australian)" in details
    assert "First contact with Hyfen (Dutch)" in details


# ----- end-to-end ------------------------------------------------------


def test_build_dashboards_produces_one_per_player(all_saves: list[Path]):
    out = dashboard.build_dashboards(all_saves)
    # 16 humans (Lion is filtered).
    assert len(out) == 16
    # Every entry has the expected shape.
    for username, data in out.items():
        assert data["player"] == username
        assert "nation" in data
        assert "current" in data
        assert "timeline" in data
        # Timeline should have at least one entry.
        assert len(data["timeline"]) >= 1


def test_andrew_dashboard_timeline_covers_all_turns(all_saves: list[Path]):
    out = dashboard.build_dashboards(all_saves)
    andrew = out["andrew"]
    turns_in_timeline = {e["turn"] for e in andrew["timeline"]}
    # Andrew has been in the game from turn 1 through 53.
    assert 1 in turns_in_timeline
    assert 53 in turns_in_timeline


def test_write_all_creates_per_player_files(tmp_path: Path, all_saves: list[Path]):
    out = dashboard.build_dashboards(all_saves)
    dashboard.write_all(out, tmp_path / "dash")
    files = sorted((tmp_path / "dash").glob("*.json"))
    assert len(files) == 16
    # Andrew's file should contain the right player name.
    import json
    andrew_data = json.loads((tmp_path / "dash" / "andrew.json").read_text())
    assert andrew_data["player"] == "andrew"


def test_full_build_finishes_under_a_minute(all_saves: list[Path]):
    """The bash version takes 9–24 minutes to do this same work.
    Anything over 60s here is a regression worth investigating."""
    start = time.monotonic()
    out = dashboard.build_dashboards(all_saves)
    elapsed = time.monotonic() - start
    print(f"\n[benchmark] full dashboard build for {len(out)} players over "
          f"{len(all_saves)} saves: {elapsed:.2f}s")
    assert len(out) == 16
    assert elapsed < 60.0, f"dashboard build took {elapsed:.1f}s — regression"
