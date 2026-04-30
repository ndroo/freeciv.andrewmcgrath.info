"""Tests for the save-file parser using real game fixtures.

Game-specific facts asserted here come from spot-checking the 2026-04-29
prod saves with `gzcat | grep`. They will need updating if the fixtures
are regenerated, but that's an acceptable cost for tests that catch real
parser regressions instead of testing synthetic toy input.
"""

from pathlib import Path

from lib.freeciv_save import Save, Table, _parse_csv_row, _strip_quotes


# ----- low-level parsing helpers ---------------------------------------


def test_parse_csv_row_simple():
    assert _parse_csv_row("1,2,3") == ["1", "2", "3"]


def test_parse_csv_row_respects_quoted_commas():
    # "Aqueduct, River" is a real building name — comma inside the quoted
    # string must NOT split the field.
    assert _parse_csv_row('"Aqueduct, River",5,"Granary"') == [
        '"Aqueduct, River"',
        "5",
        '"Granary"',
    ]


def test_parse_csv_row_keeps_empty_trailing_field():
    assert _parse_csv_row("a,b,") == ["a", "b", ""]


def test_strip_quotes():
    assert _strip_quotes('"hello"') == "hello"
    assert _strip_quotes("hello") == "hello"
    assert _strip_quotes('""') == ""


# ----- Save.parse on real fixtures -------------------------------------


def test_load_turn_53(latest_save: Path):
    s = Save.load(latest_save)
    assert s.turn == 53
    assert s.year == -1400  # 1400 BC


def test_game_section_has_known_keys(latest_save: Path):
    s = Save.load(latest_save)
    g = s.game()
    assert g is not None
    assert g.get_str("server_state") == "S_S_RUNNING"
    assert g.get_int("phase_seconds") == 1837
    assert g.get_int("scoreturn") == 68


def test_players_count_is_17(latest_save: Path):
    # 16 humans + 1 barbarian "Lion" — verified with grep.
    s = Save.load(latest_save)
    assert len(s.players()) == 17


def test_player0_is_shazow_canadian(latest_save: Path):
    s = Save.load(latest_save)
    p0 = s.players()[0]
    assert p0.get_str("name") == "Shazow"
    assert p0.get_str("username") == "shazow"
    assert p0.get_str("nation") == "Canadian"
    assert p0.get_str("government_name") == "Despotism"
    assert p0.get_int("gold") == 91
    assert p0.get_int("nunits") == 13
    assert p0.get_int("ncities") == 4
    assert p0.get_bool("is_alive") is True
    assert p0.get_bool("phase_done") is True


def test_player1_phase_not_done(latest_save: Path):
    # Hyfen had phase_done=FALSE in turn 53. Tests that bool parsing handles
    # FALSE as well as TRUE.
    s = Save.load(latest_save)
    p1 = s.players()[1]
    assert p1.get_str("name") == "Hyfen"
    assert p1.get_bool("phase_done") is False


def test_diplstate_table_is_one_row_per_player(latest_save: Path):
    # diplstate has one row per OTHER player in the game.
    s = Save.load(latest_save)
    p0 = s.players()[0]
    dip = p0.tables["diplstate"]
    assert isinstance(dip, Table)
    # Header includes "current" and "first_contact_turn" among others.
    assert "current" in dip.header
    assert "first_contact_turn" in dip.header
    # 17 player slots → 17 diplomacy rows (one per player including self).
    assert len(dip.rows) == 17


def test_diplstate_player0_vs_player1_was_war(latest_save: Path):
    # From hand-inspecting the fixture: player0 (Shazow) vs player1 (Hyfen)
    # is "War" in turn 53.
    s = Save.load(latest_save)
    p0 = s.players()[0]
    dip = p0.tables["diplstate"]
    current = dip.col("current")
    # Index 1 = relationship with player1
    assert current[1] == '"War"'


def test_table_with_quoted_commas_parses(latest_save: Path):
    # The c={...} table has city names like "Aqueduct, River" in production.
    # We just check that one of the cities parses to a quoted name.
    s = Save.load(latest_save)
    p0 = s.players()[0]
    cities = p0.tables.get("c")
    assert cities is not None
    name_col = cities.col("name")
    assert any(n.startswith('"') and n.endswith('"') for n in name_col)


def test_all_saves_parse_without_error(all_saves: list[Path]):
    """Every fixture turn loads without raising. Catches regressions on
    older save format quirks (we span turns 1 through 53)."""
    for path in all_saves:
        s = Save.load(path)
        assert s.turn > 0, f"{path.name} parsed turn 0"
        # game() is the most fundamental section — if it's missing we
        # broke something basic.
        assert s.game() is not None, f"{path.name} has no [game] section"


def test_turn_number_matches_filename(all_saves: list[Path]):
    """`lt-game-N.sav.gz` should always have `turn=N` inside."""
    for path in all_saves:
        expected = int(path.stem.split("-")[2].split(".")[0])
        s = Save.load(path)
        assert s.turn == expected, f"{path.name} reports turn {s.turn}"
