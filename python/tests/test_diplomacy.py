"""Tests + benchmark for the diplomacy builder.

The benchmark in `test_full_build_finishes_quickly` is the smoking gun
for the rewrite — the bash version timed out at 51 minutes on this exact
input. Anything above 60 seconds here is a regression worth investigating.
"""

import json
import time
from pathlib import Path

import pytest

from lib import diplomacy
from lib.freeciv_save import Save


# ----- per-save extraction ---------------------------------------------


def test_extract_relationships_drops_never_met(latest_save: Path):
    s = Save.load(latest_save)
    rels = diplomacy.extract_relationships(s)
    statuses = {r["status"] for r in rels}
    assert "Never met" not in statuses


def test_extract_relationships_drops_barbarians(latest_save: Path):
    # Lion is the barbarian player in the fixture. No relationship entry
    # should reference it.
    s = Save.load(latest_save)
    rels = diplomacy.extract_relationships(s)
    names = {n for r in rels for n in r["players"]}
    assert "Lion" not in names


def test_extract_relationships_uses_sorted_unique_pairs(latest_save: Path):
    s = Save.load(latest_save)
    rels = diplomacy.extract_relationships(s)
    seen: set[tuple[str, str]] = set()
    for r in rels:
        a, b = r["players"]
        key = (a, b) if a <= b else (b, a)
        assert key not in seen, f"duplicate pair {key}"
        seen.add(key)


def test_war_with_war_closest_displays_as_contact(latest_save: Path):
    # Per the bash logic: the freeciv default state after "Never met" is
    # War/War, which actually means "just met, no real war". We display
    # those as "Contact". This catches a lot of false positives.
    s = Save.load(latest_save)
    rels = diplomacy.extract_relationships(s)
    # At least one Contact relationship should exist in turn 53.
    statuses = [r["status"] for r in rels]
    assert "Contact" in statuses


# ----- combat-pair extraction ------------------------------------------


def test_combat_pairs_empty_when_no_combat(latest_save: Path):
    # Turn 53 has no E_UNIT_WIN/LOST events.
    s = Save.load(latest_save)
    pairs = diplomacy.extract_combat_pairs(s)
    assert pairs == set()


def test_combat_pairs_found_in_turn_45(fixture_dir: Path):
    # Turn 45 has 2 combat events (1 attack + 1 defense, same fight).
    s = Save.load(fixture_dir / "lt-game-45.sav.gz")
    pairs = diplomacy.extract_combat_pairs(s)
    # Exactly one fight, hence one pair. From the message text it's
    # German Diplomat lost to Australian Warriors → Andrew vs Jamsem24.
    assert len(pairs) == 1
    pair = next(iter(pairs))
    assert set(pair) == {"Andrew", "Jamsem24"}


# ----- full rebuild ----------------------------------------------------


def test_full_build_produces_required_fields(all_saves: list[Path]):
    out = diplomacy.build(all_saves)
    assert set(out.keys()) == {"turn", "current", "events", "combat_pairs"}
    assert out["turn"] == 53
    assert isinstance(out["current"], list)
    assert isinstance(out["events"], list)
    assert isinstance(out["combat_pairs"], list)


def test_full_build_emits_first_contact_events(all_saves: list[Path]):
    out = diplomacy.build(all_saves)
    # Every player pair that ever met should produce at least one
    # "Never met" → something event.
    first_contacts = [e for e in out["events"] if e["from"] == "Never met"]
    assert len(first_contacts) > 0


def test_full_build_combat_pairs_includes_known_fight(all_saves: list[Path]):
    # Andrew & Jamsem24 fought in turn 45 — should appear in combat_pairs.
    out = diplomacy.build(all_saves)
    pairs = {tuple(sorted(p)) for p in out["combat_pairs"]}
    assert ("Andrew", "Jamsem24") in pairs


def test_full_build_finishes_quickly(all_saves: list[Path]):
    """The bash version of this exact computation hung for 51 minutes.

    A correct python implementation should be well under 60s on 53 saves.
    If this fails over a generous 60s budget, we've regressed badly."""
    start = time.monotonic()
    out = diplomacy.build(all_saves)
    elapsed = time.monotonic() - start
    print(f"\n[benchmark] full diplomacy build over {len(all_saves)} saves: {elapsed:.2f}s")
    assert out["turn"] == 53
    assert elapsed < 60.0, f"diplomacy build took {elapsed:.1f}s — regression"


# ----- atomic write ----------------------------------------------------


def test_write_is_atomic(tmp_path: Path):
    out = tmp_path / "diplomacy.json"
    data = {"turn": 1, "current": [], "events": [], "combat_pairs": []}
    diplomacy.write(data, out)
    assert out.exists()
    assert json.loads(out.read_text()) == data
    # The .tmp file should not exist after a successful write.
    assert not (tmp_path / "diplomacy.json.tmp").exists()
